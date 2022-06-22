#!/usr/bin/env python3
import requests
from argparse import ArgumentParser
from enum import Enum


class RunTypes(Enum):
    not_found = 'not_found'
    redirects = 'redirects'

    def __str__(self):
        return self.value


def remove_prefix(text: str, prefix: str) -> str:
    """ Returns provided string without the prefix.
    """
    return text[len(prefix):] if text.rfind(prefix) == 0 else text


def check_redirect(full_url: str, base_url: str):
    """ Checks if the URL has non-200 status code and prints the redirect destination or the status code
    """
    try:
        req = requests.get(full_url)
    except requests.exceptions.TooManyRedirects:
        print(f"too many redirects on {remove_prefix(full_url, base_url)}")
        return
    if remove_prefix(full_url, base_url) != remove_prefix(req.url, base_url):
        print(f"redirect: {remove_prefix(full_url, base_url)}")
    if req.status_code != 200:
        print(f"code {req.status_code}: {remove_prefix(full_url, base_url)}")


def main(run_type: str, site: str, urls_file: str):
    for line in open(urls_file, 'r').readlines():
        full_url = site + remove_prefix(line.strip(), site)
        if run_type == "redirects":
            check_redirect(full_url, site)


if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('--site',
                        dest="site",
                        default="https://favor-group.ru",
                        help='Site URL without trailing slash')
    parser.add_argument('--file',
                        dest="urls_file",
                        default="urls.txt",
                        help='File with URLs list divided by newlines')
    parser.add_argument(
        'run_type',
        type=RunTypes,
        choices=list(RunTypes),
        help="Type of the run: either check for redirects and pages "
             "with wrong status codes, or something which is not yet implemented."
    )
    opts = parser.parse_args()
    main(str(opts.run_type), opts.site, opts.urls_file)
