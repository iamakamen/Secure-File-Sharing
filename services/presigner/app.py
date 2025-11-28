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
    """
    Simple presigner Lambda:
    - Reads JSON body: { "file_key": "path/file.txt", "expires": 3600 }
    - Uses username from event['requestContext']['authorizer']['username'] if present
    - Creates a presigned GET URL for that S3 object
    - Writes an audit log entry to DynamoDB
    """

    # Safely parse body
    body_str = event.get("body") or "{}"
    try:
        body = json.loads(body_str)
    except json.JSONDecodeError:
        body = {}

    # Who is the user? (for now fallback to "anonymous")
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


    # File key and expiry
    file_key = body.get("file_key") or f"{user}/{uuid.uuid4()}"
    expires = body.get("expires", 3600)

    # Make sure expires is an int and within a safe range
    try:
        expires = int(expires)
    except (TypeError, ValueError):
        expires = 3600

    if expires <= 0 or expires > 24 * 3600:
        # limit to max 24 hours
        expires = 3600

    # Generate presigned URL for GET
    presigned_url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": FILES_BUCKET, "Key": file_key},
        ExpiresIn=expires,
    )

    # Try to get the source IP from different possible places
    # HTTP API v2: requestContext.http.sourceIp
    # REST API / older: requestContext.identity.sourceIp
    http_ctx = request_context.get("http", {})
    identity_ctx = request_context.get("identity", {})

    headers = event.get("headers") or {}
    # Headers in HTTP API are usually all lowercased
    # x-forwarded-for might contain "client-ip, proxy1, proxy2"
    xff = headers.get("x-forwarded-for") or headers.get("X-Forwarded-For")

    source_ip = (
        http_ctx.get("sourceIp")
        or identity_ctx.get("sourceIp")
        or (xff.split(",")[0].strip() if isinstance(xff, str) else None)
        or "unknown"
    )

    # Put audit record
    audit_table = dynamodb.Table(AUDIT_TABLE)
    audit_item = {
        "audit_id": str(uuid.uuid4()),
        "ts": datetime.utcnow().isoformat(),
        "user": user,
        "action": "generate_presigned_get",
        "file_key": file_key,
        "expires_in_seconds": expires,
        "source_ip": source_ip,
    }
    audit_table.put_item(Item=audit_item)

    # Return response (like API Gateway proxy)
    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "presigned_url": presigned_url,
                "file_key": file_key,
                "expires_in_seconds": expires,
            }
        ),
    }
