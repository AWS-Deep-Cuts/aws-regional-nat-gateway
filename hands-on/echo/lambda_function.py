# AWS Deep Cuts - Regional NAT Gateway ハンズオン: IP 確認用の関数
# 関数 URL で呼び出され、呼び出し元の送信元 IP を 1 行で返す。
# 関数 URL は認証なし（AuthType=NONE）でインターネットに公開されるため、
# setup.sh が作成したトークンが URL のクエリ token= に付いた呼び出しだけに応答する。
import hmac
import json
import os

TOKEN = os.environ["ECHO_TOKEN"].encode()


def lambda_handler(event, context):
    params = event.get("queryStringParameters") or {}
    # トークンが一致しない呼び出しには、送信元 IP を返さず、このコードはログに何も書かない
    if not hmac.compare_digest(params.get("token", "").encode(), TOKEN):
        return {"statusCode": 403, "headers": {"Content-Type": "text/plain"}, "body": "invalid token"}
    # 関数 URL のリクエストでは、呼び出し元の送信元 IP が requestContext.http.sourceIp に入る
    # AWS の CDK の統合テストも、同じ値で regional NAT ゲートウェイの送信元 IP を確かめている
    source_ip = event["requestContext"]["http"]["sourceIp"]
    az = params.get("az", "-")
    # ログに書くのは送信元 IP と AZ の名前だけ。トークンは書かない
    print(json.dumps({"source_ip": source_ip, "az": az}))
    return {"statusCode": 200, "headers": {"Content-Type": "text/plain"}, "body": source_ip}
