#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Regional NAT Gateway ハンズオンの後片付け
# setup.sh と README の手順で作成したリソースを、すべて削除します。
#
# このスクリプトの方針
#   - どの手順でやめた場合も、何度実行しても使えるように、resource-ids.env に保存した ID ではなく、
#     タグ Project=aws-deepcuts-rnat と VPC の ID と状態で、リソースを探して削除する。
#   - AWS の呼び出しが失敗しても止まらずに次の段へ進み、NAT ゲートウェイの削除と EIP の解放まで必ず進む。
#   - 料金がいちばん大きい NAT ゲートウェイの削除の依頼を最初に出し、待つのは後にする。
#   - 探した結果が 0 件のときは、aws ec2 wait を呼ばない（0 件のまま呼ぶと、最大 10 分待って失敗するため）。
#   - 最後に、タグで残っているリソースを探し、残っていれば ❌ を表示して終了コード 1 で終わる。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
# resource-ids.env が無いときの表示にも使うため、読み込む前にも設定する
PROJECT="aws-deepcuts-rnat"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Regional NAT Gateway 後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ -f "${RESOURCE_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${RESOURCE_FILE}"
else
  echo "⚠️ ${RESOURCE_FILE} が見つかりません。タグ Project=${PROJECT} でリソースを探して削除します。"
fi
# resource-ids.env にも PROJECT があるため、読み込んだ後にも設定し直す
PROJECT="aws-deepcuts-rnat"
REGION="${REGION:-${DEEPCUTS_REGION:-ap-northeast-1}}"
ECHO_FUNCTION="${ECHO_FUNCTION:-${PROJECT}-echo}"
ECHO_ROLE="${ECHO_ROLE:-${PROJECT}-echo-role}"
ECHO_LOG_GROUP="${ECHO_LOG_GROUP:-/aws/lambda/${ECHO_FUNCTION}}"
readonly TAG_FILTER="Name=tag:Project,Values=${PROJECT}"
echo "リージョン: ${REGION}"
echo ""

FAILS=0
LAST=""   # 直前の try・retry の結果（ok・gone・fail）
# AWS の呼び出しを 1 つ実行する。失敗しても止めない。対象がすでに無い場合は失敗に数えない
try() {
  local what="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    LAST="ok"
    return 0
  fi
  if grep -qE 'NotFound|does not exist|ResourceNotFoundException|NoSuchEntity' <<<"${out}"; then
    echo "  - ${what}: すでにありません"
    LAST="gone"
  else
    echo "  ⚠️ ${what}: $(head -n 1 <<<"${out}")"
    FAILS=$((FAILS + 1))
    LAST="fail"
  fi
  return 0
}

# 直前の try・retry が成功したときだけ、結果の行を表示する
report() {
  if [[ "${LAST}" == "ok" ]]; then
    echo "  $1"
  fi
  return 0
}

# --output text の出力を、空白区切りの重複の無い一覧にする（None と空の行を除く）
words() {
  tr -s '[:space:]' '\n' | grep -vx -e 'None' -e '' | sort -u | tr '\n' ' ' | sed 's/ $//' || true
}

# 読み取りの呼び出しを実行し、結果を words の形で返す。失敗したら ⚠️ を標準エラーに表示して空を返す
lookup() {
  local what="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    words <<<"${out}"
  else
    echo "  ⚠️ ${what}: $(head -n 1 <<<"${out}")" >&2
  fi
}

# 複数行の文字列を、行ごとに字下げして表示する
indent() {
  local line
  while IFS= read -r line; do
    echo "     ${line}"
  done <<<"$1"
}

# 2 つの一覧を合わせ、重複を除く
merge() {
  printf '%s\n' "$@" | words
}

# ─── 対象の VPC を探す ────────────────────────────────────────
TAGGED_VPCS=$(lookup "VPC の検索" aws ec2 describe-vpcs --region "${REGION}" \
  --filters "${TAG_FILTER}" --query 'Vpcs[].VpcId' --output text)
# resource-ids.env の VPC_ID は、まだ存在する場合だけ使う
SAVED_VPC=""
if [[ -n "${VPC_ID:-}" ]]; then
  SAVED_VPC=$(lookup "VPC の確認" aws ec2 describe-vpcs --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Vpcs[].VpcId' --output text)
fi
VPCS=$(merge "${TAGGED_VPCS}" "${SAVED_VPC}")
echo "対象の VPC: ${VPCS:-なし}"
echo ""

# タグ、または対象の VPC の中で、指定した状態の NAT ゲートウェイを探す
find_nat_gateways() {
  local states="$1" found=""
  found=$(lookup "NAT ゲートウェイの検索" aws ec2 describe-nat-gateways --region "${REGION}" \
    --filter "${TAG_FILTER}" "Name=state,Values=${states}" \
    --query 'NatGateways[].NatGatewayId' --output text)
  local vpc
  for vpc in ${VPCS}; do
    found=$(merge "${found}" "$(lookup "NAT ゲートウェイの検索" aws ec2 describe-nat-gateways --region "${REGION}" \
      --filter "Name=vpc-id,Values=${vpc}" "Name=state,Values=${states}" \
      --query 'NatGateways[].NatGatewayId' --output text)")
  done
  echo "${found}"
}

# タグ、または対象の VPC の中で、終了していないインスタンスを探す
find_instances() {
  local states="pending,running,stopping,stopped,shutting-down" found=""
  found=$(lookup "インスタンスの検索" aws ec2 describe-instances --region "${REGION}" \
    --filters "${TAG_FILTER}" "Name=instance-state-name,Values=${states}" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  local vpc
  for vpc in ${VPCS}; do
    found=$(merge "${found}" "$(lookup "インスタンスの検索" aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=vpc-id,Values=${vpc}" "Name=instance-state-name,Values=${states}" \
      --query 'Reservations[].Instances[].InstanceId' --output text)")
  done
  echo "${found}"
}

# エラーの文字列を見て、最大 N 回まで 10 秒おきに繰り返す（DependencyViolation などのとき）
retry() {
  local what="$1" times="$2"; shift 2
  local out i
  for i in $(seq 1 "${times}"); do
    if out=$("$@" 2>&1); then
      LAST="ok"
      return 0
    fi
    if grep -qE 'NotFound|does not exist' <<<"${out}"; then
      echo "  - ${what}: すでにありません"
      LAST="gone"
      return 0
    fi
    if [[ "${i}" -lt "${times}" ]]; then
      sleep 10
    fi
  done
  echo "  ⚠️ ${what}: $(head -n 1 <<<"${out}")"
  FAILS=$((FAILS + 1))
  LAST="fail"
  return 0
}

# ─── [0/8] NAT ゲートウェイの時刻を表示する（補助）─────────────────
echo "[0/8] このハンズオンの NAT ゲートウェイの作成と削除の時刻（補助。時刻は UTC）..."
ALL_NATS=$(find_nat_gateways "pending,failed,available,deleting,deleted")
if [[ -n "${ALL_NATS}" ]]; then
  # shellcheck disable=SC2086
  aws ec2 describe-nat-gateways --region "${REGION}" --nat-gateway-ids ${ALL_NATS} \
    --query "NatGateways[].[NatGatewayId, Tags[?Key=='Name'] | [0].Value, CreateTime, DeleteTime, State]" --output table 2>/dev/null || true
else
  echo "  表示できる NAT ゲートウェイはありません"
fi
echo "  削除済みの NAT ゲートウェイは、しばらくすると表示されなくなります。"
echo "  手順 8 には、各手順で記録した観測記録表の表 1 の時刻を使ってください。"
echo ""

# ─── [1/8] NAT ゲートウェイの削除を依頼 ─────────────────────────────
echo "[1/8] NAT ゲートウェイの削除を依頼..."
NATS=$(find_nat_gateways "pending,available")
if [[ -z "${NATS}" ]]; then
  echo "  対象なし"
else
  for NAT in ${NATS}; do
    try "NAT ゲートウェイ ${NAT} の削除の依頼" aws ec2 delete-nat-gateway --region "${REGION}" --nat-gateway-id "${NAT}"
    report "削除を依頼: ${NAT}"
  done
  echo "  依頼した時刻: $(date -u +%H:%M:%S) UTC（観測記録表の表 1 の「7」の行に写してください）"
fi
echo ""

# ─── [2/8] 確認用のインスタンスの終了を依頼 ─────────────────────────
echo "[2/8] 確認用のインスタンスの終了を依頼..."
INSTANCES=$(find_instances)
if [[ -z "${INSTANCES}" ]]; then
  echo "  対象なし"
else
  # shellcheck disable=SC2086
  try "インスタンスの終了の依頼" aws ec2 terminate-instances --region "${REGION}" --instance-ids ${INSTANCES}
  report "終了を依頼: ${INSTANCES}"
fi
echo ""

# ─── [3/8] NAT ゲートウェイの削除を待つ ─────────────────────────────
echo "[3/8] NAT ゲートウェイの削除を待機（数分かかります）..."
WAIT_NATS=$(find_nat_gateways "pending,available,deleting")
if [[ -z "${WAIT_NATS}" ]]; then
  echo "  対象なし"
else
  # aws ec2 wait nat-gateway-deleted は最大 10 分待つ。終わらなければ、もう 1 回待つ（合計で最大 20 分）
  for ATTEMPT in 1 2; do
    # shellcheck disable=SC2086
    try "NAT ゲートウェイの削除の待機（${ATTEMPT} 回目）" aws ec2 wait nat-gateway-deleted --region "${REGION}" --nat-gateway-ids ${WAIT_NATS}
    LEFT=$(find_nat_gateways "pending,available,deleting")
    [[ -z "${LEFT}" ]] && break
    WAIT_NATS="${LEFT}"
  done
  echo "  deleted になった時刻: $(date -u +%H:%M:%S) UTC（観測記録表の表 1 の「7」の行に写してください）"
fi
echo ""

# ─── [4/8] EIP を解放 ─────────────────────────────────────────────
echo "[4/8] EIP を解放..."
ALLOCS=$(lookup "EIP の検索" aws ec2 describe-addresses --region "${REGION}" \
  --filters "${TAG_FILTER}" --query 'Addresses[].AllocationId' --output text)
if [[ -z "${ALLOCS}" ]]; then
  echo "  対象なし"
else
  for ALLOC in ${ALLOCS}; do
    # NAT ゲートウェイの削除の直後は、関連付けが残っていて解放できないことがあるため、10 秒おきに最大 2 分試す
    retry "EIP ${ALLOC} の解放" 12 aws ec2 release-address --region "${REGION}" --allocation-id "${ALLOC}"
    report "解放: ${ALLOC}"
  done
fi
# 自動モードの regional NAT ゲートウェイが割り当てた EIP は、ServiceManaged が rnat で表示される。
# 2026 年 11 月の観測では、NAT ゲートウェイが deleted になった直後に一覧から消えたこともあれば、
# 直後はまだ表示され、約 20 分後のこのスクリプトの実行時には消えていたこともあった。
# 残った場合に自分で解放してよいかは確かめられていないため、ここでは解放せず、表示だけする。
RNAT=$(aws ec2 describe-addresses --region "${REGION}" \
  --query "Addresses[?ServiceManaged=='rnat'].[PublicIp,AllocationId]" --output text 2>/dev/null || true)
if [[ -n "${RNAT}" && "${RNAT}" != "None" ]]; then
  echo "  ⚠️ regional NAT ゲートウェイが管理する EIP（ServiceManaged が rnat）が表示されています。"
  echo "     このハンズオン以外の regional NAT ゲートウェイを使っている場合は、その EIP も表示されます。"
  indent "${RNAT}"
fi
echo ""

# ─── [5/8] サブネット・ルートテーブル・セキュリティグループを削除 ──────────
echo "[5/8] サブネット・ルートテーブル・セキュリティグループを削除..."
if [[ -n "${INSTANCES}" ]]; then
  echo "  インスタンスの終了を待機..."
  # shellcheck disable=SC2086
  try "インスタンスの終了の待機" aws ec2 wait instance-terminated --region "${REGION}" --instance-ids ${INSTANCES}
fi
if [[ -z "${VPCS}" ]]; then
  echo "  対象の VPC が無いため、スキップします"
fi
for VPC in ${VPCS}; do
  # インスタンスや NAT ゲートウェイの ENI が残っているとサブネットを削除できないため、10 秒おきに最大 3 分試す
  SUBNETS=$(lookup "サブネットの検索" aws ec2 describe-subnets --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC}" --query 'Subnets[].SubnetId' --output text)
  for SUBNET in ${SUBNETS}; do
    retry "サブネット ${SUBNET} の削除" 18 aws ec2 delete-subnet --region "${REGION}" --subnet-id "${SUBNET}"
    report "削除: サブネット ${SUBNET}"
  done
  # メインのルートテーブルは VPC と一緒に削除されるため、それ以外のルートテーブルを削除する
  RTS=$(lookup "ルートテーブルの検索" aws ec2 describe-route-tables --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC}" \
    --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text)
  for RT in ${RTS}; do
    retry "ルートテーブル ${RT} の削除" 18 aws ec2 delete-route-table --region "${REGION}" --route-table-id "${RT}"
    report "削除: ルートテーブル ${RT}"
  done
  SGS=$(lookup "セキュリティグループの検索" aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC}" "Name=group-name,Values=${PROJECT}-check-sg" \
    --query 'SecurityGroups[].GroupId' --output text)
  for SG in ${SGS}; do
    retry "セキュリティグループ ${SG} の削除" 18 aws ec2 delete-security-group --region "${REGION}" --group-id "${SG}"
    report "削除: セキュリティグループ ${SG}"
  done
done
echo ""

# ─── [6/8] インターネットゲートウェイと VPC を削除 ─────────────────────
echo "[6/8] インターネットゲートウェイと VPC を削除..."
for VPC in ${VPCS}; do
  IGWS=$(lookup "インターネットゲートウェイの検索" aws ec2 describe-internet-gateways --region "${REGION}" \
    --filters "Name=attachment.vpc-id,Values=${VPC}" \
    --query 'InternetGateways[].InternetGatewayId' --output text)
  for IGW in ${IGWS}; do
    # VPC の中にパブリック IP の使用が残っていると切り離せないことがあるため、10 秒おきに最大 3 分試す
    retry "インターネットゲートウェイ ${IGW} の切り離し" 18 aws ec2 detach-internet-gateway --region "${REGION}" \
      --internet-gateway-id "${IGW}" --vpc-id "${VPC}"
    report "切り離し: ${IGW}"
  done
done
# タグで探したインターネットゲートウェイ（切り離し済みのものを含む）を削除する
IGWS=$(lookup "インターネットゲートウェイの検索" aws ec2 describe-internet-gateways --region "${REGION}" \
  --filters "${TAG_FILTER}" --query 'InternetGateways[].InternetGatewayId' --output text)
for IGW in ${IGWS}; do
  ATTACHED=$(lookup "インターネットゲートウェイの確認" aws ec2 describe-internet-gateways --region "${REGION}" \
    --internet-gateway-ids "${IGW}" --query 'InternetGateways[0].Attachments[].VpcId' --output text)
  for VPC in ${ATTACHED}; do
    retry "インターネットゲートウェイ ${IGW} の切り離し" 18 aws ec2 detach-internet-gateway --region "${REGION}" \
      --internet-gateway-id "${IGW}" --vpc-id "${VPC}"
  done
  try "インターネットゲートウェイ ${IGW} の削除" aws ec2 delete-internet-gateway --region "${REGION}" --internet-gateway-id "${IGW}"
  report "削除: インターネットゲートウェイ ${IGW}"
done
for VPC in ${VPCS}; do
  retry "VPC ${VPC} の削除" 18 aws ec2 delete-vpc --region "${REGION}" --vpc-id "${VPC}"
  report "削除: VPC ${VPC}"
done
echo ""

# ─── [7/8] IP 確認用の関数を削除 ───────────────────────────────────
echo "[7/8] IP 確認用の関数・ロググループ・IAM ロールを削除..."
try "関数 URL の削除" aws lambda delete-function-url-config --region "${REGION}" --function-name "${ECHO_FUNCTION}"
try "Lambda 関数の削除" aws lambda delete-function --region "${REGION}" --function-name "${ECHO_FUNCTION}"
report "削除: Lambda 関数 ${ECHO_FUNCTION}"
try "ロググループの削除" aws logs delete-log-group --region "${REGION}" --log-group-name "${ECHO_LOG_GROUP}"
report "削除: ロググループ ${ECHO_LOG_GROUP}"
try "IAM ロールのポリシーの削除" aws iam delete-role-policy --role-name "${ECHO_ROLE}" --policy-name "${PROJECT}-echo-logs"
try "IAM ロールの削除" aws iam delete-role --role-name "${ECHO_ROLE}"
report "削除: IAM ロール ${ECHO_ROLE}"
echo ""

# ─── [8/8] ローカルのファイルを削除 ─────────────────────────────────
echo "[8/8] ローカルのファイルを削除..."
rm -f "${SCRIPT_DIR}/egress-check.sh" "${SCRIPT_DIR}/echo.zip"
echo "  削除: egress-check.sh・echo.zip"
echo ""

# ─── 残っていないかを確かめる（VPC の ID に頼らず、タグと名前で探す）─────────
echo "残っているリソースを確認..."
ERRORS=0
# 確認の呼び出しが失敗したときも、残っていないとは言えないため ❌ に数える
check() {
  local what="$1"; shift
  local out
  if ! out=$("$@" 2>&1); then
    echo "  ❌ ${what}: 確認できませんでした（$(head -n 1 <<<"${out}")）"
    ERRORS=$((ERRORS + 1))
    return 0
  fi
  out=$(words <<<"${out}")
  if [[ -n "${out}" ]]; then
    echo "  ❌ ${what}: ${out}"
    ERRORS=$((ERRORS + 1))
  fi
  return 0
}
check "NAT ゲートウェイ" aws ec2 describe-nat-gateways --region "${REGION}" \
  --filter "${TAG_FILTER}" "Name=state,Values=pending,available,deleting" \
  --query 'NatGateways[].NatGatewayId' --output text
check "インスタンス" aws ec2 describe-instances --region "${REGION}" \
  --filters "${TAG_FILTER}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[].InstanceId' --output text
check "EIP" aws ec2 describe-addresses --region "${REGION}" \
  --filters "${TAG_FILTER}" --query 'Addresses[].AllocationId' --output text
check "VPC" aws ec2 describe-vpcs --region "${REGION}" \
  --filters "${TAG_FILTER}" --query 'Vpcs[].VpcId' --output text
check "インターネットゲートウェイ" aws ec2 describe-internet-gateways --region "${REGION}" \
  --filters "${TAG_FILTER}" --query 'InternetGateways[].InternetGatewayId' --output text
if aws lambda get-function --region "${REGION}" --function-name "${ECHO_FUNCTION}" >/dev/null 2>&1; then
  echo "  ❌ Lambda 関数: ${ECHO_FUNCTION}"
  ERRORS=$((ERRORS + 1))
fi
if aws iam get-role --role-name "${ECHO_ROLE}" >/dev/null 2>&1; then
  echo "  ❌ IAM ロール: ${ECHO_ROLE}"
  ERRORS=$((ERRORS + 1))
fi
check "ロググループ" aws logs describe-log-groups --region "${REGION}" \
  --log-group-name-prefix "${ECHO_LOG_GROUP}" \
  --query "logGroups[?logGroupName=='${ECHO_LOG_GROUP}'].logGroupName" --output text
RNAT=$(aws ec2 describe-addresses --region "${REGION}" \
  --query "Addresses[?ServiceManaged=='rnat'].[PublicIp,AllocationId]" --output text 2>/dev/null || true)
[[ "${RNAT}" == "None" ]] && RNAT=""
echo ""

if [[ "${ERRORS}" -gt 0 ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "❌ 削除できなかったリソースがあります。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
if [[ "${FAILS}" -gt 0 ]]; then
  echo "途中で ⚠️ が ${FAILS} 件表示されましたが、残っているリソースは見つかりませんでした。"
  echo ""
fi
if [[ -n "${RNAT}" ]]; then
  echo "  ⚠️ regional NAT ゲートウェイが管理する EIP（ServiceManaged が rnat）が表示されています。"
  indent "${RNAT}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ このハンズオンのタグがついたリソースの削除は完了しました。"
  echo "⚠️ の EIP は、数分おいて bash ./cleanup.sh を再実行し、残る場合は README のトラブルシューティングを確認してください。"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
fi
rm -f "${RESOURCE_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
