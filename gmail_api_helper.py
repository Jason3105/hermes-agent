import json
import os
import urllib.request
import urllib.parse
import base64
from email.mime.text import MIMEText

def get_access_token():
    """Exchanges the refresh token for a fresh, short-lived access token."""
    client_id = os.environ.get("GOOGLE_CLIENT_ID")
    client_secret = os.environ.get("GOOGLE_CLIENT_SECRET")
    refresh_token = os.environ.get("GOOGLE_REFRESH_TOKEN")

    if not client_id or not client_secret or not refresh_token:
        raise ValueError("Missing required Google OAuth environment variables!")

    token_url = "https://oauth2.googleapis.com/token"
    token_data = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token"
    }).encode("utf-8")

    req = urllib.request.Request(token_url, data=token_data, headers={"Content-Type": "application/x-www-form-urlencoded"})

    with urllib.request.urlopen(req) as response:
        res_data = json.loads(response.read().decode("utf-8"))
        return res_data["access_token"]

def send_gmail(to_email, subject, body_text):
    """Sends an email using the Gmail REST API over HTTPS."""
    # 1. Get access token dynamically
    access_token = get_access_token()

    # 2. Build standard MIME email
    msg = MIMEText(body_text)
    msg["to"] = to_email
    msg["subject"] = subject

    # 3. Gmail API expects RFC 2822 formatted message encoded in base64url
    raw_message = base64.urlsafe_b64encode(msg.as_bytes()).decode("utf-8")

    # 4. Make HTTPS POST request to Gmail send endpoint
    url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json"
    }
    data = json.dumps({"raw": raw_message}).encode("utf-8")

    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    
    with urllib.request.urlopen(req) as response:
        result = json.loads(response.read().decode("utf-8"))
        print(f"Email sent successfully! Message ID: {result.get('id')}")
        return result
