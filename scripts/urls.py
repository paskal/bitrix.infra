#!/usr/bin/env python3
from typing import Optional
import requests
from argparse import ArgumentParser
from enum import Enum
from urllib.parse import unquote

_redirects_map_path = '../config/nginx/conf.d/redirects-map.conf'
_default_site = 'https://favor-group.ru'


class RunTypes(Enum):
    redirects = 'redirects'
    chain_redirects = 'chain_redirects'
    bad_status_codes = 'bad_status_codes'

    def __str__(self):
        return self.value


class UrlChecker:
    def __init__(self, site: str = _default_site, update_redirects: bool = False):
        self.site = site
        self.write = update_redirects
        # https://stackoverflow.com/a/17141572/961092
        if self.write:
            with open(_redirects_map_path, 'r') as redirects_file:
                self.redirects_map = redirects_file.read()

    def __del__(self):
        if self.write:
            with open(_redirects_map_path, 'w') as redirects_file:
                redirects_file.write(self.redirects_map)

    def relative(self, text: str, utf8: bool = True) -> str:
        """ Returns provided URL without the site prefix, e.g. relative URL.
        Also unquotes the URL if the flag is not overwritten.
        Spaces are not unquoted as they would mess up the redirects map.
        """
        relative_url = text[len(self.site):] if text.rfind(self.site) == 0 else text
        return unquote(relative_url).replace(' ', '%20') if utf8 else relative_url

    def update_redirect(self, text: str, substitute: str):
        """ Replaces provided text with substitute in the redirects map, in case writes are enabled.
        """
        if self.write:
            self.redirects_map = self.redirects_map.replace(text, substitute)

    def retrieve_url(self, relative_url: str) -> Optional[requests.Response]:
        """Returns response for the provided URL,
        or prints error message and returns nothing in case of infinite redirect."""
        try:
            resp = requests.get(self.site + relative_url)
        except requests.exceptions.TooManyRedirects:
            print(f"too many redirects on {relative_url}")
            return
        return resp

    def check_redirect(self, resp: requests.Response, relative_url: str):
        """Prints URL and status code of the provided response if it has non-200 status code,
        or URL and it's redirect final destination or the status code in case it's not 301 or 302.
        """
        if relative_url != self.relative(resp.url):
            self.update_redirect(relative_url, self.relative(resp.url))
            print(f"{relative_url} -> {self.relative(resp.url)}")
        self.bad_status_codes(resp, relative_url)

    def chain_redirects(self, resp: requests.Response, relative_url: str):
        """Prints original redirect or the URL, and its final destination in case there is a chain of redirects.
        That turns out to be useful to simplify redirects as well as for SEO, as original redirect might be to
        non-indexed search page while the final destination might be SEO-friendly page,
        but the search engine would never know."""
        if len(resp.history) > 1:
            self.update_redirect(relative_url, self.relative(resp.url))
            print(f"{self.relative(resp.history[1].url)} -> {self.relative(resp.url)}")
        self.bad_status_codes(resp, relative_url)

    @staticmethod
    def bad_status_codes(resp: requests.Response, relative_url: str):
        """Prints URL and status code of the provided response if it has non-200 and not 301 or 302 status code.
        """
        if resp.status_code != 200:
            print(f"code {resp.status_code}: {relative_url}")



def main(run_type: str, site: str, urls_file: str, update_redirects: bool):
    url_checker = UrlChecker(site, update_redirects)
    for line in open(urls_file, 'r').readlines():
        relative_url = url_checker.relative(line.strip(), False)  # keep original URL unquoted
        resp = url_checker.retrieve_url(relative_url)
        if not resp:
            continue
        if run_type == "redirects":
            url_checker.check_redirect(resp, relative_url)
        if run_type == "chain_redirects":
            url_checker.chain_redirects(resp, relative_url)
        if run_type == "bad_status_codes":
            url_checker.bad_status_codes(resp, site)


if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('--site',
                        dest="site",
                        default=_default_site,
                        type=str,
                        help='Site URL without trailing slash')
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
