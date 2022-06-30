#!/usr/bin/env python3
import requests
from argparse import ArgumentParser
from enum import Enum


class RunTypes(Enum):
    redirects = 'redirects'
    not_found = 'simplify_redirects'
    bad_status_codes = 'bad_status_codes'

    def __str__(self):
        return self.value


def remove_prefix(text: str, prefix: str) -> str:
    """ Returns provided string without the prefix.
    """
    return text[len(prefix):] if text.rfind(prefix) == 0 else text


def retrieve_url(site: str, relative_url: str) -> requests.Response:
    """Returns response for the provided URL,
    or prints error message and returns nothing in case of infinite redirect."""
    try:
        resp = requests.get(site + relative_url)
    except requests.exceptions.TooManyRedirects:
        print(f"too many redirects on {relative_url}")
        return
    return resp


def check_redirect(resp: requests.Response, base_url: str, relative_url: str):
    """Prints URL and status code of the provided response if it has non-200 status code,
    or URL and it's redirect final destination or the status code in case it's not 301 or 302.
    """
    if relative_url != remove_prefix(resp.url, base_url):
        print(f"redirect: {relative_url} -> {remove_prefix(resp.url, base_url)}")
    bad_status_codes(resp, relative_url)


def simplify_redirects(resp: requests.Response, base_url: str):
    """Prints original redirect or the URL, and its final destination in case there is a chain of redirects.
    That turns out to be useful to simplify redirects as well as for SEO, as original redirect might be to
    non-indexed search page while the final destination might be SEO-friendly page,
    but the search engine would never know."""
    if len(resp.history) > 1:
        print(f"{remove_prefix(resp.history[1].url, base_url)}"
              f" -> {remove_prefix(resp.url, base_url)}")
    bad_status_codes(resp, remove_prefix(resp.history[0].url, base_url))


def bad_status_codes(resp: requests.Response, relative_url: str):
    """Prints URL and status code of the provided response if it has non-200 and not 301 or 302 status code.
    """
    if resp.status_code != 200:
        print(f"code {resp.status_code}: {relative_url}")


def main(run_type: str, site: str, urls_file: str):
    for line in open(urls_file, 'r').readlines():
        relative_url = remove_prefix(line.strip(), site)
        resp = retrieve_url(site, relative_url)
        if not resp:
            continue
        if run_type == "redirects":
            check_redirect(resp, site, relative_url)
        if run_type == "simplify_redirects":
            simplify_redirects(resp, site)
        if run_type == "bad_status_codes":
            bad_status_codes(resp, site)


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
        help="Type of the run: either check for redirects and pages with wrong status codes,"
             " or only print redirect chains which could be simplified,"
             " or only pages which are not redirects with wrong status codes."
    )
    opts = parser.parse_args()
    main(str(opts.run_type), opts.site, opts.urls_file)
