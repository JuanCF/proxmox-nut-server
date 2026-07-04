#!/usr/bin/env python3
import argparse
import getpass
import sys
import time

from services import auth_db


def _prompt_password(prompt: str, given: str | None) -> str | None:
    if given is not None:
        return given
    password = getpass.getpass(prompt)
    confirm = getpass.getpass("Confirm " + prompt[0].lower() + prompt[1:])
    if password != confirm:
        print("Passwords do not match", file=sys.stderr)
        return None
    return password


def cmd_create_admin(args):
    password = _prompt_password("Password: ", args.password)
    if password is None:
        return 1
    if len(password) < 8:
        print("Password must be at least 8 characters", file=sys.stderr)
        return 1
    existing = auth_db.get_account_by_username(args.username)
    if existing:
        auth_db.update_account(existing["id"], role="admin", password=password, is_active=True)
        print(f"Promoted existing account '{args.username}' to admin and reset its password.")
        return 0
    account, err = auth_db.create_account(args.username, password, role="admin")
    if err:
        print(f"Error: {err}", file=sys.stderr)
        return 1
    print(f"Created admin account '{account['username']}'.")
    return 0


def cmd_reset_password(args):
    account = auth_db.get_account_by_username(args.username)
    if account is None:
        print(f"No such account: {args.username}", file=sys.stderr)
        return 1
    password = _prompt_password("New password: ", args.password)
    if password is None:
        return 1
    if len(password) < 8:
        print("Password must be at least 8 characters", file=sys.stderr)
        return 1
    auth_db.update_account(account["id"], password=password)
    print(f"Password reset for '{args.username}'.")
    return 0


def cmd_list_accounts(args):
    accounts = auth_db.list_accounts()
    if not accounts:
        print("No accounts configured. The app is running fully open (no auth).")
        return 0
    print(f"{'USERNAME':<20}{'ROLE':<10}{'ACTIVE':<8}{'LAST LOGIN'}")
    for a in accounts:
        last_login = (
            time.strftime("%Y-%m-%d %H:%M", time.localtime(a["last_login_at"]))
            if a["last_login_at"]
            else "never"
        )
        print(f"{a['username']:<20}{a['role']:<10}{'yes' if a['is_active'] else 'no':<8}{last_login}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="NutWatch account management (bootstrap / lockout recovery)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_create = sub.add_parser("create-admin", help="Create a new admin account, or promote+reset an existing one")
    p_create.add_argument("username")
    p_create.add_argument("--password", help="Password (omit to be prompted)")
    p_create.set_defaults(func=cmd_create_admin)

    p_reset = sub.add_parser("reset-password", help="Reset an existing account's password")
    p_reset.add_argument("username")
    p_reset.add_argument("--password", help="New password (omit to be prompted)")
    p_reset.set_defaults(func=cmd_reset_password)

    p_list = sub.add_parser("list-accounts", help="List accounts, roles, and active status")
    p_list.set_defaults(func=cmd_list_accounts)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
