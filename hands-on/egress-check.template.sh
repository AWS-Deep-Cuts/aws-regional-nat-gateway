#!/bin/bash
set -euo pipefail

# AWS Deep Cuts - Regional NAT Gateway ハンズオン: 確認用のインスタンスのユーザーデータ
#
# setup.sh が、このひな形の __ECHO_URL__ と __ECHO_TOKEN__ を置き換えて egress-check.sh を作成します。
# README の手順 4-3 と 5-1 で、egress-check.sh を run-instances の --user-data に指定します。
# インスタンスの初回の起動時に、このスクリプトが root の権限で 1 回だけ実行され、次の 3 つを行います。
#
#   1. 起動から 180 分後に OS をシャットダウンする予約をする。
#      インスタンスは --instance-initiated-shutdown-behavior terminate で起動するため、シャットダウンすると終了する。
#      後片付けを忘れても、インスタンスの料金は最大 3 時間で止まる。
#   2. インスタンスメタデータ（IMDSv2）から、インスタンスのある AZ の名前を取得する。
#   3. 30 秒ごとに IP 確認用の関数を呼び出し、結果を 1 行ずつコンソール出力に書く処理を、
#      systemd のサービス egress-check として起動する。
#      コンソール出力に書く行の形: [egress-check] <UTC の時刻> az=<AZ の名前> egress=<送信元 IP または FAIL>
#      関数が IPv4 アドレスを返したときは、その IP アドレスを書く。
#      タイムアウト・HTTP のエラー・invalid token のときは FAIL と書く。トークンはコンソール出力に書かない。
#
# 要確認: Amazon Linux 2023 の arm64 のインスタンスで、/dev/console に書いた行が
#         aws ec2 get-console-output --latest に表示されること。表示されない場合は、
#         egress-check-loop.sh の書き先を /dev/ttyS0 に変更する。

ECHO_URL="__ECHO_URL__"
ECHO_TOKEN="__ECHO_TOKEN__"

# ─── 1. 180 分後にシャットダウンする ─────────────────────────────
shutdown -h +180 "AWS Deep Cuts: 起動から 180 分が経過したため終了します"

# ─── 2. AZ の名前を取得する（IMDSv2）──────────────────────────────
AZ=""
for _ in $(seq 1 10); do
  IMDS_TOKEN=$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
  AZ=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "http://169.254.169.254/latest/meta-data/placement/availability-zone" || true)
  [[ "${AZ}" =~ ^[a-z0-9-]+$ ]] && break
  AZ=""
  sleep 3
done
AZ="${AZ:-unknown}"

# ─── 3. 確認のループを systemd のサービスとして起動する ───────────────
# cloud-init の終了に左右されずに動き続けるよう、systemd-run で起動する。
# 関数の URL とトークンは、root だけが読めるファイルに保存する。
install -m 600 /dev/null /etc/egress-check.env
cat > /etc/egress-check.env <<EOF
ECHO_URL="${ECHO_URL}"
ECHO_TOKEN="${ECHO_TOKEN}"
AZ="${AZ}"
EOF

cat > /usr/local/bin/egress-check-loop.sh <<'LOOP'
#!/bin/bash
set -euo pipefail
# shellcheck source=/dev/null
source /etc/egress-check.env
while true; do
  RESPONSE=$(curl -s -m 5 "${ECHO_URL}?token=${ECHO_TOKEN}&az=${AZ}" || true)
  if [[ "${RESPONSE}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    EGRESS="${RESPONSE}"
  else
    EGRESS="FAIL"
  fi
  echo "[egress-check] $(date -u +%H:%M:%S) az=${AZ} egress=${EGRESS}" > /dev/console
  sleep 30
done
LOOP
chmod 700 /usr/local/bin/egress-check-loop.sh

systemd-run --unit egress-check /usr/local/bin/egress-check-loop.sh
