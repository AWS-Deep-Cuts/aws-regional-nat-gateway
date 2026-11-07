#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Regional NAT Gateway ハンズオンの事前準備
# NAT ゲートウェイ・サブネット・インスタンス・EIP は、README の手順で 1 コマンドずつ作成します。
# このスクリプトは、その前提になる次のものだけを作成します。
#   1. VPC（10.0.0.0/16）とインターネットゲートウェイ
#   2. プライベートサブネット用のルートテーブル（ルートとサブネットの関連付けは、README の手順で追加する）
#   3. 確認用のインスタンスのセキュリティグループ（インバウンドのルールなし）
#   4. IP 確認用の関数（Lambda 関数と関数 URL）、その IAM ロール、ロググループ
#   5. 確認用のインスタンスのユーザーデータ egress-check.sh（ローカルのファイル）
# 作成したリソースの ID は、作成した直後に resource-ids.env に追記します。

readonly PROJECT="aws-deepcuts-rnat"
REGION="${DEEPCUTS_REGION:-ap-northeast-1}"
INSTANCE_TYPE="${DEEPCUTS_INSTANCE_TYPE:-t4g.nano}"
readonly VPC_NAME="${PROJECT}-vpc"
readonly IGW_NAME="${PROJECT}-igw"
readonly RT_NAME="${PROJECT}-private-rt"
readonly SG_NAME="${PROJECT}-check-sg"
readonly ECHO_FUNCTION="${PROJECT}-echo"
readonly ECHO_ROLE="${PROJECT}-echo-role"
readonly ECHO_LOG_GROUP="/aws/lambda/${ECHO_FUNCTION}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
readonly TAGS="{Key=Project,Value=${PROJECT}}"

# 作成した直後に、変数を resource-ids.env に 1 行追記する（途中で失敗しても cleanup.sh で片付けられるように）
save() {
  local name="$1" value="$2"
  echo "${name}=\"${value}\"" >> "${RESOURCE_FILE}"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Regional NAT Gateway 事前準備"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/7] 前提の確認 ─────────────────────────────────────────
echo "[1/7] 前提を確認..."
if [[ -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が既に存在します。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
if ! aws ec2 create-nat-gateway --generate-cli-skeleton input 2>/dev/null | grep -q '"AvailabilityMode"'; then
  echo "❌ Error: この AWS CLI は create-nat-gateway の --availability-mode に対応していません（2.32.0 以降が必要です）。" >&2
  echo "   現在のバージョン: $(aws --version 2>&1)" >&2
  echo "   README の「前提条件」の手順で、ホームディレクトリに最新版の AWS CLI をインストールしてください。" >&2
  exit 1
fi
for cmd in zip curl python3 sed; do
  command -v "${cmd}" >/dev/null || { echo "❌ Error: ${cmd} コマンドが見つかりません。" >&2; exit 1; }
done
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "❌ Error: AWS の認証情報を取得できません。CloudShell で実行しているか確認してください。" >&2
  exit 1
}
# 前回の環境が resource-ids.env の無いまま残っていないかを確かめる（同じ名前のリソースを二重に作らないため）
LEFT_VPC=$(aws ec2 describe-vpcs --region "${REGION}" \
  --filters "Name=tag:Project,Values=${PROJECT}" --query 'Vpcs[].VpcId' --output text)
if [[ -n "${LEFT_VPC}" && "${LEFT_VPC}" != "None" ]]; then
  echo "❌ Error: タグ Project=${PROJECT} の VPC が残っています: ${LEFT_VPC}" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
if aws lambda get-function --function-name "${ECHO_FUNCTION}" --region "${REGION}" >/dev/null 2>&1; then
  echo "❌ Error: Lambda 関数 ${ECHO_FUNCTION} が残っています。先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION} / インスタンスタイプ: ${INSTANCE_TYPE}"

cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts Regional NAT Gateway - リソース情報（setup.sh が作成。README の手順で行を追記します）
REGION="${REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
PROJECT="${PROJECT}"
INSTANCE_TYPE="${INSTANCE_TYPE}"
EOF
echo "  リソース情報の保存先: ${RESOURCE_FILE}"
echo ""

# ─── [2/7] AZ と AMI を選ぶ ─────────────────────────────────────
echo "[2/7] 3 つの AZ と、確認用のインスタンスの AMI を選択..."
# AZ A・AZ B: インスタンスを起動するため、このインスタンスタイプを起動できる AZ から選ぶ
OFFERED=$(aws ec2 describe-instance-type-offerings --region "${REGION}" \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | grep -v '^$' | sort || true)
# AZ C: サブネットだけを置くため、インスタンスタイプは問わない。オプトインの不要な、使える AZ から選ぶ
# 注意: 自動モードの NAT ゲートウェイは、サブネットが無くても、作成した時点で 1 つの AZ に EIP を関連付けた
#       （2026 年 11 月の観測）。AZ はこのスクリプトが NAT ゲートウェイの作成より前に選ぶため、その AZ を除けない。
#       その AZ が AZ C なら、手順 4 の比較では拡張のきっかけを判定できない（README の手順 2-2 の注意）。
ALL_AZ=$(aws ec2 describe-availability-zones --region "${REGION}" \
  --filters Name=zone-type,Values=availability-zone Name=state,Values=available Name=opt-in-status,Values=opt-in-not-required \
  --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | grep -v '^$' | sort || true)
AZ_A=$(sed -n '1p' <<<"${OFFERED}")
AZ_B=$(sed -n '2p' <<<"${OFFERED}")
AZ_C=""
if [[ -n "${AZ_A}" && -n "${AZ_B}" ]]; then
  AZ_C=$(grep -vx -e "${AZ_A}" -e "${AZ_B}" <<<"${ALL_AZ}" | sed -n '1p' || true)
fi
if [[ -z "${AZ_A}" || -z "${AZ_B}" || -z "${AZ_C}" ]]; then
  echo "❌ 3 つの AZ を選べません。DEEPCUTS_REGION で別のリージョンを指定してください。" >&2
  echo "   ${INSTANCE_TYPE} を起動できる AZ: ${OFFERED:-なし}" >&2
  echo "   bash ./cleanup.sh を実行してから、やり直してください。" >&2
  exit 1
fi
read -r AZ_A_ID AZ_B_ID AZ_C_ID < <(aws ec2 describe-availability-zones --region "${REGION}" \
  --zone-names "${AZ_A}" "${AZ_B}" "${AZ_C}" \
  --query "[AvailabilityZones[?ZoneName=='${AZ_A}'].ZoneId | [0], AvailabilityZones[?ZoneName=='${AZ_B}'].ZoneId | [0], AvailabilityZones[?ZoneName=='${AZ_C}'].ZoneId | [0]]" \
  --output text) || true
if [[ -z "${AZ_C_ID:-}" || "${AZ_C_ID}" == "None" ]]; then
  echo "❌ Error: AZ の ID を取得できません。" >&2
  exit 1
fi
save AZ_A "${AZ_A}"
save AZ_B "${AZ_B}"
save AZ_C "${AZ_C}"
save AZ_A_ID "${AZ_A_ID}"
save AZ_B_ID "${AZ_B_ID}"
save AZ_C_ID "${AZ_C_ID}"

# インスタンスタイプのアーキテクチャに合わせて、Amazon Linux 2023 の最新の AMI を選ぶ
ARCHS=$(aws ec2 describe-instance-types --region "${REGION}" --instance-types "${INSTANCE_TYPE}" \
  --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)
if grep -qw arm64 <<<"${ARCHS}"; then ARCH="arm64"; else ARCH="x86_64"; fi
AMI_ID=$(aws ssm get-parameters --region "${REGION}" \
  --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${ARCH}" \
  --query 'Parameters[0].Value' --output text)
if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  echo "❌ Error: Amazon Linux 2023（${ARCH}）の AMI の ID を取得できません。" >&2
  exit 1
fi
save AMI_ID "${AMI_ID}"
echo "  AZ A: ${AZ_A}（${AZ_A_ID}）  AZ B: ${AZ_B}（${AZ_B_ID}）  AZ C: ${AZ_C}（${AZ_C_ID}）"
echo "  AMI:  ${AMI_ID}（Amazon Linux 2023、${ARCH}）"
echo ""

# ─── [3/7] VPC とインターネットゲートウェイ ──────────────────────────
echo "[3/7] VPC とインターネットゲートウェイを作成..."
VPC_ID=$(aws ec2 create-vpc --region "${REGION}" --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${VPC_NAME}},${TAGS}]" \
  --query Vpc.VpcId --output text)
save VPC_ID "${VPC_ID}"
aws ec2 wait vpc-available --region "${REGION}" --vpc-ids "${VPC_ID}"
# パブリックサブネットは作らない。インターネットゲートウェイは取り付ける。
# AWS の CDK と Terraform の regional NAT ゲートウェイの例とテストも、
# パブリックサブネットの無い VPC に、インターネットゲートウェイを先に取り付けている。
IGW_ID=$(aws ec2 create-internet-gateway --region "${REGION}" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${IGW_NAME}},${TAGS}]" \
  --query InternetGateway.InternetGatewayId --output text)
save IGW_ID "${IGW_ID}"
aws ec2 attach-internet-gateway --region "${REGION}" --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
echo "  VPC: ${VPC_ID}（${VPC_NAME}）"
echo "  インターネットゲートウェイ: ${IGW_ID}（${IGW_NAME}）を VPC に取り付けました"
echo ""

# ─── [4/7] ルートテーブル ───────────────────────────────────────
echo "[4/7] プライベートサブネット用のルートテーブルを作成..."
# ルート（0.0.0.0/0）とサブネットの関連付けは、README の手順 3・4・5 であなたが追加する
RT_ID=$(aws ec2 create-route-table --region "${REGION}" --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${RT_NAME}},${TAGS}]" \
  --query RouteTable.RouteTableId --output text)
save RT_ID "${RT_ID}"
echo "  ルートテーブル: ${RT_ID}（${RT_NAME}）"
echo ""

# ─── [5/7] セキュリティグループ ──────────────────────────────────
echo "[5/7] 確認用のインスタンスのセキュリティグループを作成..."
# インバウンドのルールは追加しない。既定のアウトバウンドのルール（すべての送信を許可）だけを使う
SG_ID=$(aws ec2 create-security-group --region "${REGION}" \
  --group-name "${SG_NAME}" \
  --description "AWS Deep Cuts Regional NAT Gateway hands-on (no inbound rules)" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},${TAGS}]" \
  --query GroupId --output text)
save SG_ID "${SG_ID}"
echo "  セキュリティグループ: ${SG_ID}（${SG_NAME}）"
echo ""

# ─── [6/7] IP 確認用の関数 ──────────────────────────────────────
echo "[6/7] IP 確認用の関数を作成..."
# IP 確認用の関数は、呼び出し元の送信元 IP を返す Lambda 関数で、VPC の外に置く。
# 関数 URL は認証なし（AuthType=NONE）でインターネットに公開される。
# AWS の Agent Skill は、NONE を使うときは、関数のコードの中の認証と組み合わせるよう書いている。
# そのため、関数は、このスクリプトが作成した乱数のトークンが URL に付いた呼び出しだけに送信元 IP を返す。
# それ以外の呼び出しには 403 を返し、関数のコードはログに何も書かない。Lambda が書く実行の開始と終了の行は残る。
# 関数はハンズオンの間だけ置き、cleanup.sh で削除する。
ECHO_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
save ECHO_TOKEN "${ECHO_TOKEN}"
save ECHO_FUNCTION "${ECHO_FUNCTION}"
save ECHO_ROLE "${ECHO_ROLE}"
save ECHO_LOG_GROUP "${ECHO_LOG_GROUP}"

# ロググループ（保持期間 1 日）
if aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${ECHO_LOG_GROUP}" \
     --query "logGroups[?logGroupName=='${ECHO_LOG_GROUP}'] | length(@)" --output text | grep -q '^[1-9]'; then
  echo "  既に存在するため、そのまま使います: ${ECHO_LOG_GROUP}"
else
  aws logs create-log-group --region "${REGION}" --log-group-name "${ECHO_LOG_GROUP}" --tags "Project=${PROJECT}"
  echo "  ロググループ: ${ECHO_LOG_GROUP}"
fi
aws logs put-retention-policy --region "${REGION}" --log-group-name "${ECHO_LOG_GROUP}" --retention-in-days 1

# IAM ロール（Lambda が引き受け、ロググループにログを書く権限だけを持つ）
if aws iam get-role --role-name "${ECHO_ROLE}" >/dev/null 2>&1; then
  echo "  既に存在するため、そのまま使います: ${ECHO_ROLE}"
else
  aws iam create-role --role-name "${ECHO_ROLE}" \
    --description "AWS Deep Cuts Regional NAT Gateway hands-on (IP echo function)" \
    --tags "Key=Project,Value=${PROJECT}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null
  echo "  IAM ロール: ${ECHO_ROLE}"
fi
aws iam put-role-policy --role-name "${ECHO_ROLE}" --policy-name "${PROJECT}-echo-logs" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"WriteEchoLogs\",
      \"Effect\": \"Allow\",
      \"Action\": [\"logs:CreateLogStream\", \"logs:PutLogEvents\"],
      \"Resource\": \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${ECHO_LOG_GROUP}:*\"
    }]
  }"
ROLE_ARN=$(aws iam get-role --role-name "${ECHO_ROLE}" --query Role.Arn --output text)

# 関数のコードを zip にする
rm -f "${SCRIPT_DIR}/echo.zip"
zip -q -j "${SCRIPT_DIR}/echo.zip" "${SCRIPT_DIR}/echo/lambda_function.py"

# 作成した直後の IAM ロールは、Lambda から引き受けられないことがあるため、10 秒おきに最大 6 回試す
CREATED=""
for i in $(seq 1 6); do
  if OUT=$(aws lambda create-function --region "${REGION}" \
      --function-name "${ECHO_FUNCTION}" \
      --runtime python3.13 --architectures arm64 \
      --handler lambda_function.lambda_handler \
      --role "${ROLE_ARN}" \
      --zip-file "fileb://${SCRIPT_DIR}/echo.zip" \
      --timeout 3 --memory-size 128 \
      --environment "Variables={ECHO_TOKEN=${ECHO_TOKEN}}" 2>&1); then
    CREATED="yes"
    break
  fi
  if grep -q 'cannot be assumed' <<<"${OUT}" && [[ "${i}" -lt 6 ]]; then
    echo "  IAM ロールの反映を待っています（${i}/6）..."
    sleep 10
  else
    echo "❌ Error: Lambda 関数を作成できませんでした: $(head -n 1 <<<"${OUT}")" >&2
    exit 1
  fi
done
[[ -n "${CREATED}" ]] || { echo "❌ Error: Lambda 関数を作成できませんでした。" >&2; exit 1; }
aws lambda wait function-active-v2 --region "${REGION}" --function-name "${ECHO_FUNCTION}"
echo "  Lambda 関数: ${ECHO_FUNCTION}"

ECHO_URL=$(aws lambda create-function-url-config --region "${REGION}" \
  --function-name "${ECHO_FUNCTION}" --auth-type NONE \
  --query FunctionUrl --output text)
save ECHO_URL "${ECHO_URL}"
# AuthType=NONE の関数 URL を呼び出せるようにするには、2 つの文をリソースベースのポリシーに追加する
aws lambda add-permission --region "${REGION}" --function-name "${ECHO_FUNCTION}" \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl --principal '*' \
  --function-url-auth-type NONE >/dev/null
aws lambda add-permission --region "${REGION}" --function-name "${ECHO_FUNCTION}" \
  --statement-id FunctionURLInvokeAllowPublicAccess \
  --action lambda:InvokeFunction --principal '*' \
  --invoked-via-function-url >/dev/null
echo "  関数 URL: ${ECHO_URL}"

# CloudShell から呼び出して、送信元 IP が返ることを確かめる（反映を待つため、5 秒おきに最大 12 回）
ECHO_OK=""
for _ in $(seq 1 12); do
  RESPONSE=$(curl -s -m 5 "${ECHO_URL}?token=${ECHO_TOKEN}&az=setup" || true)
  if [[ "${RESPONSE}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ECHO_OK="yes"
    break
  fi
  sleep 5
done
if [[ -n "${ECHO_OK}" ]]; then
  echo "  CloudShell から呼び出した結果: ${RESPONSE}（CloudShell の送信元 IP）"
else
  echo "  ⚠️ 関数 URL の呼び出しで IP アドレスが返りませんでした。README の手順 1 で、もう一度試してください。"
fi
# トークンを付けない呼び出しが 403 になることを確かめる
NO_TOKEN_CODE=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${ECHO_URL}?az=no-token" || true)
if [[ "${NO_TOKEN_CODE}" == "403" ]]; then
  echo "  トークンを付けない呼び出しは 403 になりました"
else
  echo "  ⚠️ トークンを付けない呼び出しの結果が 403 ではありません（${NO_TOKEN_CODE}）。"
fi
echo ""

# ─── [7/7] 確認用のインスタンスのユーザーデータ ─────────────────────
echo "[7/7] 確認用のインスタンスのユーザーデータ egress-check.sh を作成..."
# egress-check.sh にはトークンが入るため、Git の管理から外している（hands-on/.gitignore）
# 置き換えるのは、コメント以外の行だけにする（ひな形の説明のコメントの中の名前は、そのまま残す）
sed -e "/^[[:space:]]*#/!s|__ECHO_URL__|${ECHO_URL}|" -e "/^[[:space:]]*#/!s|__ECHO_TOKEN__|${ECHO_TOKEN}|" \
  "${SCRIPT_DIR}/egress-check.template.sh" > "${SCRIPT_DIR}/egress-check.sh"
chmod 600 "${SCRIPT_DIR}/egress-check.sh"
echo "  作成: ${SCRIPT_DIR}/egress-check.sh"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "このハンズオンで使う 3 つの AZ（実際の名前はアカウントによって異なります）"
echo "  AZ A: ${AZ_A}  サブネットと確認用のインスタンスを置く"
echo "  AZ B: ${AZ_B}  サブネットと確認用のインスタンスを置く（手順 5 まで何も作らない）"
echo "  AZ C: ${AZ_C}  サブネットだけを置く比較用の AZ"
echo ""
echo "作成したリソースは、マネジメントコンソールの次の画面で確認できます。"
echo "  VPC:            https://${REGION}.console.aws.amazon.com/vpcconsole/home?region=${REGION}#VpcDetails:VpcId=${VPC_ID}"
echo "  ルートテーブル: https://${REGION}.console.aws.amazon.com/vpcconsole/home?region=${REGION}#RouteTableDetails:RouteTableId=${RT_ID}"
echo "  Lambda 関数:    https://${REGION}.console.aws.amazon.com/lambda/home?region=${REGION}#/functions/${ECHO_FUNCTION}"
echo ""
echo "次のステップ: README の手順 1 に戻り、次のコマンドで変数を読み込んでください。"
echo "  source ./resource-ids.env"
