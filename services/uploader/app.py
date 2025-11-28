import os
import json
import uuid
from datetime import datetime
import boto3

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")

FILES_BUCKET = os.environ["FILES_BUCKET"]
AUDIT_TABLE = os.environ["AUDIT_TABLE"]


def lambda_handler(event, context):
    body_str = event.get("body") or "{}"
    try:
        body = json.loads(body_str)
    except:
        body = {}

    request_context = event.get("requestContext", {})
    auth_ctx = request_context.get("authorizer", {})
    jwt = auth_ctx.get("jwt", {})
    claims = jwt.get("claims", {})

    user = (
        claims.get("cognito:username")
        or claims.get("email")
        or claims.get("sub")
        or "anonymous"
    )


    filename = body.get("filename")
    if not filename:
        filename = f"upload-{uuid.uuid4()}"

    file_key = f"{user}/{filename}"
    expires = body.get("expires", 1800)  # 30 min default

    # Create a presigned PUT URL
    presigned_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": FILES_BUCKET, "Key": file_key},
        ExpiresIn=int(expires)
    )

    # Detect IP
    http_ctx = request_context.get("http", {})
    identity_ctx = request_context.get("identity", {})
    headers = event.get("headers") or {}
    xff = headers.get("x-forwarded-for") or headers.get("X-Forwarded-For")

    source_ip = (
        http_ctx.get("sourceIp")
        or identity_ctx.get("sourceIp")
        or (xff.split(",")[0].strip() if isinstance(xff, str) else None)
        or "unknown"
    )

    # Store metadata + audit log
    audit_table = dynamodb.Table(AUDIT_TABLE)
    audit_table.put_item(Item={
        "audit_id": str(uuid.uuid4()),
        "ts": datetime.utcnow().isoformat(),
        "user": user,
        "action": "generate_presigned_put",
        "file_key": file_key,
        "expires": expires,
        "source_ip": source_ip,
    })

    return {
        "statusCode": 200,
        "body": json.dumps({
            "upload_url": presigned_url,
            "file_key": file_key,
            "expires_in_seconds": expires,
        }),
    }
