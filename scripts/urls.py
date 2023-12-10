#!/usr/bin/env python3
from argparse import ArgumentParser
from enum import Enum
from typing import Optional
from urllib.parse import urljoin
from lxml.html import fromstring

import requests

_redirects_map_path = '../config/nginx/conf.d/redirects-map.conf'
_default_site = 'https://favor-group.ru'


class RunTypes(Enum):
    redirects = 'redirects'
    chain_redirects = 'chain_redirects'
    bad_status_codes = 'bad_status_codes'
    titles = 'titles'

    def __str__(self):
        return self.value


class UrlChecker:
    def __init__(self, update_redirects: bool = False):
        self.write = update_redirects
        # https://stackoverflow.com/a/17141572/961092
        if self.write:
            with open(_redirects_map_path, 'r') as redirects_file:
                self.redirects_map = redirects_file.read()

    def __del__(self):
        if self.write:
            with open(_redirects_map_path, 'w') as redirects_file:
                redirects_file.write(self.redirects_map)

    def update_redirect(self, text: str, substitute: str):
        """ Replaces provided text with substitute in the redirects map, in case writes are enabled.
        """
        if self.write:
            self.redirects_map = self.redirects_map.replace(text, substitute)

    @staticmethod
    def retrieve_url(url: str) -> Optional[requests.Response]:
        """Returns response for the provided URL,
        or prints error message and returns nothing in case of infinite redirect."""
        try:
            resp = requests.get(url)
        except requests.exceptions.TooManyRedirects:
            print(f"too many redirects on {url}")
            return
        except Exception as ex:
            print(f"can't retrieve {url}: {ex}")
            return
        return resp

    def check_redirect(self, resp: requests.Response, url: str):
        """Prints URL and status code of the provided response if it has non-200 status code,
        or URL, and it's redirect final destination or the status code in case it's not 301 or 302.
        """
        if url != resp.url:
            self.update_redirect(url, resp.url)
            print(f"{url} -> {resp.url}")
        self.bad_status_codes(resp, url)

    def chain_redirects(self, resp: requests.Response, url: str):
        """Prints original redirect or the URL, and its final destination in case there is a chain of redirects.
        That turns out to be useful to simplify redirects as well as for SEO, as original redirect might be to
        non-indexed search page while the final destination might be SEO-friendly page,
        but the search engine would never know."""
        if len(resp.history) > 1:
            self.update_redirect(url, resp.url)
            print(f"{resp.history[1].url} -> {resp.url}")
        self.bad_status_codes(resp, url)

    @staticmethod
    def bad_status_codes(resp: requests.Response, url: str):
        """Prints URL and status code of the provided response if it has non-200 and not 301 or 302 status code.
        """
        if resp.status_code != 200:
            print(f"code {resp.status_code}: {url}")


def main(run_type: str, site: str, urls_file: str, update_redirects: bool):
    url_checker = UrlChecker(update_redirects)
    for line in open(urls_file, 'r').readlines():
        # skip empty lines and comments
        if not line.strip() or line.strip().startswith("#"):
            continue
        absolute_url = line.strip()
        # convert relative URLs to absolute
        if not absolute_url.startswith("https://"):
            absolute_url = urljoin(site, absolute_url)
        resp = url_checker.retrieve_url(absolute_url)
        if resp is None:
            continue
        if run_type == "titles":
            title = fromstring(resp.content).findtext('.//title')
            url = resp.url.removeprefix("https://favor-group.ru")
            print(f"{url};{title}")
        if run_type == "redirects":
            url_checker.check_redirect(resp, absolute_url)
        if run_type == "chain_redirects":
            url_checker.chain_redirects(resp, absolute_url)
        if run_type == "bad_status_codes":
            url_checker.bad_status_codes(resp, absolute_url)


if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('--site',
                        dest="site",
                        default=_default_site,
                        type=str,
                        help='Site URL, needed only if relative links are provided')
    parser.add_argument('--file',
                        dest="urls_file",
                        default="urls.txt",
                        type=str,
                        help='File with URLs list divided by newlines')
    parser.add_argument('--update_redirects',
                        dest="update_redirects",
                        action='store_true',
                        help='Replace the old redirects with the new ones in redirects-map.conf')
    parser.add_argument(
        'run_type',
        type=RunTypes,
        choices=list(RunTypes),
        help="Type of the run: either check for redirects and pages with wrong status codes,"
             " or only print redirect chains which could be simplified,"
             " or only pages which are not redirects with wrong status codes."
    )
    opts = parser.parse_args()
    main(str(opts.run_type), opts.site, opts.urls_file, opts.update_redirects)

