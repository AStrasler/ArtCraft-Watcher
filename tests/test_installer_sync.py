"""Offline tests for the installer download boundary."""
import unittest
from unittest.mock import patch
from urllib.request import Request

from installers import sync


class InstallerURLSecurityTests(unittest.TestCase):
    def test_latest_release_requires_exact_https_api_endpoint(self):
        self.assertTrue(
            sync._allowed_github_url(
                "https://api.github.com/repos/storytold/designcraft/releases/latest",
                "designcraft",
            )
        )
        for url in (
            "http://api.github.com/repos/storytold/designcraft/releases/latest",
            "https://api.github.com.evil.test/repos/storytold/designcraft/releases/latest",
            "https://api.github.com/repos/storytold/designcraft/releases/latest?next=https://evil.test",
            "https://user@api.github.com/repos/storytold/designcraft/releases/latest",
            "https://api.github.com:8443/repos/storytold/designcraft/releases/latest",
            "file:///repos/storytold/designcraft/releases/latest",
        ):
            with self.subTest(url=url):
                self.assertFalse(sync._allowed_github_url(url, "designcraft"))

    def test_release_asset_must_match_expected_app_and_filename(self):
        allowed = "https://github.com/storytold/designcraft/releases/download/v1.2.3/designcraft-windows-x64.msi"
        self.assertTrue(sync._allowed_github_url(allowed, "designcraft", "designcraft-windows-x64.msi"))
        self.assertFalse(sync._allowed_github_url(allowed, "effectcraft", "designcraft-windows-x64.msi"))
        self.assertFalse(sync._allowed_github_url(allowed, "designcraft", "other.msi"))
        self.assertFalse(
            sync._allowed_github_url(
                "https://github.com/storytold/designcraft/releases/download/v1.2.3/%2e%2e/other.msi",
                "designcraft",
                "designcraft-windows-x64.msi",
            )
        )

    def test_invalid_initial_url_is_rejected_before_opening(self):
        with patch.object(sync, "build_opener") as build_opener:
            with self.assertRaises(ValueError):
                sync.fetch("https://evil.test/release", "designcraft", token="secret")
            build_opener.assert_not_called()

    def test_redirects_are_limited_and_authorization_is_stripped(self):
        handler = sync.GitHubRedirectHandler("designcraft", "designcraft-windows-x64.msi")
        request = Request(
            "https://github.com/storytold/designcraft/releases/download/v1.2.3/designcraft-windows-x64.msi",
            headers={"Authorization": "Bearer secret", "User-Agent": "installer-test"},
        )
        redirected = handler.redirect_request(
            request,
            None,
            302,
            "Found",
            {},
            "https://release-assets.githubusercontent.com/asset/content",
        )
        self.assertEqual(redirected.full_url, "https://release-assets.githubusercontent.com/asset/content")
        self.assertFalse(any(key.lower() == "authorization" for key in redirected.headers))
        self.assertTrue(any(key.lower() == "user-agent" for key in redirected.headers))

        for destination in (
            "https://evil.test/asset",
            "http://release-assets.githubusercontent.com/asset",
            "https://release-assets.githubusercontent.com:8443/asset",
        ):
            with self.subTest(destination=destination):
                with self.assertRaises(RuntimeError):
                    handler.redirect_request(request, None, 302, "Found", {}, destination)


if __name__ == "__main__":
    unittest.main()
