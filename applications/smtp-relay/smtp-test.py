#!/usr/bin/env python3
"""Send one test message through the relay and print whether it was accepted.

Usage:
  SMTP_PASSWORD=... ./smtp-test.py <login> <mail_from> <rcpt> [--host H] [--port P] [--no-starttls]

Use "-" as login to try without logging in. The password is read from the
SMTP_PASSWORD environment variable so it never appears in shell history or ps.
"""
import argparse
import os
import smtplib
import ssl

p = argparse.ArgumentParser()
p.add_argument("login")
p.add_argument("mail_from")
p.add_argument("rcpt")
p.add_argument("--host", default="smtp.vngenterprise.com")
p.add_argument("--port", type=int, default=587)
p.add_argument("--no-starttls", action="store_true")
a = p.parse_args()

msg = (
    f"From: {a.mail_from}\r\nTo: {a.rcpt}\r\nSubject: smtp-relay test\r\n\r\n"
    "Test message from applications/smtp-relay/smtp-test.py\r\n"
)
try:
    s = smtplib.SMTP(a.host, a.port, timeout=20)
    s.ehlo()
    if not a.no_starttls:
        s.starttls(context=ssl.create_default_context())
        s.ehlo()
    if a.login != "-":
        s.login(a.login, os.environ["SMTP_PASSWORD"])
    s.sendmail(a.mail_from, [a.rcpt], msg)
    s.quit()
    print("ACCEPTED")
except Exception as e:  # report every refusal the same way
    print("REFUSED", type(e).__name__, e)
