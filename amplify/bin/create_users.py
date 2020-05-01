#!/usr/bin/env python3
# Adds users to the Canvas dev instance based on emails in a file, one per line.
# pip install asyncio aiohttp[speedups] aiofiles
# ./create_users.py --users_file ./users.txt --token <token>
# To get a token see https://canvas.instructure.com/doc/api/file.oauth.html#manual-token-generation
from os import path
import time
import argparse

import asyncio
import aiohttp
import aiofiles
import logging
import getpass

MAX_CONNECTIONS = 2   # limit amount of simultaneously opened connections
REQUEST_TIMEOUT = aiohttp.ClientTimeout(total=30.0 * 60.0)  # 30 mins
LOG_INTERVAL = 2  # in secs
DNS_CACHE_TIME = 3600  # 1 hour, load balancer IP addr shouldn't change

CANVAS_DEV_API_URL = 'https://canvas.poc.learning.amplify.com/api/'
DEFAULT_BIRTHDAY = '2000-01-01'
DEFAULT_PASSWORD = 'Demo1234'

last_log = 0
users_created_count = 0


def write_counts(force=False):
    global last_log
    if force or (time.time() - last_log > LOG_INTERVAL):
        sys.stdout.write(f'\rusers created: {users_created_count}')
        sys.stdout.flush()
        last_log = time.time()


async def get_account_info(conn, token, account_name):
    url = f'{CANVAS_DEV_API_URL}v1/accounts'
    headers = {'accept': 'application/json; charset=utf-8',
               'Authorization': f'Bearer {token}'}
    logger.debug(f'GET: {url}\n{headers}')
    async with aiohttp.request('get', url, headers=headers, connector=conn, timeout=REQUEST_TIMEOUT) as resp:
        if resp.status != 200:
            logger.error(resp)
            raise Exception(resp)
        accounts = await resp.json()
        for account in accounts:
            if account['name'] == account_name:
                return account['id']


async def get_account_id(conn, token, account):
    if account.isdigit():
        return account
    return await get_account_info(conn, token, account)


async def create_user(conn, token, account_id, email):
    global users_created_count
    logger.debug(f'Creating: {email}')

    url = f'{CANVAS_DEV_API_URL}v1/accounts/{account_id}/users'
    headers = {'Authorization': f"Bearer {token}",
               'content-type': 'application/json; charset=utf-8'}
    body = {
        "user": {
            "name": email,
            "birthday": DEFAULT_BIRTHDAY,
            "terms_of_use": True,
            "skip_registration": True
        },
        "pseudonym": {
            "unique_id": email,
            "send_confirmation": False,
            "password": DEFAULT_PASSWORD
        },
        "communication_channel": {
            "type": "email",
            "address": email,
            "skip_confirmation": True
        }
    }
    logger.debug(f'POST: {url}\n{headers}/n{body}')
    async with aiohttp.request('post', url, json=body, headers=headers,
                               connector=conn, timeout=REQUEST_TIMEOUT) as response:
        if response.status == 200:
            users_created_count += 1
            write_counts()
        else:
            logger.error(f'Unable to create user {email}')
            logger.debug(response)


async def main(account, users_path, token, max_conn):
    async with aiohttp.TCPConnector(limit=max_conn, ttl_dns_cache=DNS_CACHE_TIME) as conn:
        account_id = await get_account_id(conn, token, account)
        async with aiofiles.open(users_path) as users_reader:
            tasks = []
            write_counts(force=True)
            try:
                async for user_email in users_reader:
                    tasks.append(
                        create_user(conn, token, account_id, user_email.strip())
                    )
                await asyncio.gather(*tasks)
            finally:
                write_counts(force=True)


if __name__ == "__main__":
    import pathlib
    import sys

    assert sys.version_info >= (3, 7), "Script requires Python 3.7+."
    here = pathlib.Path(__file__).parent

    # Instantiate the parser
    parser = argparse.ArgumentParser(
        description='Creates users in our Canvas dev instance in the specified account based on email address.',
        epilog='ex: python3 create_users.py --account Amplify --users_file canvas_dev_users.txt --debug --token <token>'
    )
    parser.add_argument('--account', default='Amplify', help="The name of the account the users should be created in. If int, assumes it is an id.")
    parser.add_argument('--token', help="The env specific KC service user password (https://canvas.instructure.com/doc/api/file.oauth.html#manual-token-generation)")
    parser.add_argument('--users_file', help='Path to file of email addresses representing users to create.')
    parser.add_argument('--max_connections', default=MAX_CONNECTIONS, type=int,
                        help='Max number of connections to have open simultaneously. Should be used to throttle.')
    parser.add_argument('--timeout', default=60, type=int,
                        help='How long connections will stay open in mins. Should be longer than you need the script to run.')
    parser.add_argument('--debug', action='store_true', default=False,
                        help='Enable debug level logging')

    args = parser.parse_args()
    LOG_LEVEL = logging.DEBUG if args.debug else logging.INFO
    logging.basicConfig(
        format="%(asctime)s %(levelname)s:%(name)s: %(message)s",
        level=LOG_LEVEL,
        datefmt="%H:%M:%S",
        stream=sys.stderr,
    )
    logger = logging.getLogger(__name__)
    logging.getLogger("chardet.charsetprober").disabled = True

    if args.users_file and not path.isfile(args.users_file):
        print(f"File path {args.users_file} does not exist. Exiting...")
        sys.exit()

    if not args.token:
        args.token = getpass.getpass(prompt="Enter a Canvas dev account admin user's token: ")

    if args.timeout:
        REQUEST_TIMEOUT = aiohttp.ClientTimeout(total=args.timeout * 60.0)

    s = time.perf_counter()
    asyncio.run(main(args.account, args.users_file, args.token, max_conn=args.max_connections))
    elapsed = time.perf_counter() - s
    print(f"\n{__file__} executed in {elapsed:0.2f} seconds.")
