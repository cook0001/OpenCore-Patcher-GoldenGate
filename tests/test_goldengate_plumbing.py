import io
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from opencore_legacy_patcher import constants, sucatalog
from opencore_legacy_patcher.datasets import os_data
from opencore_legacy_patcher.sucatalog.constants import CatalogVersion, SeedType
from opencore_legacy_patcher.support import macos_installer_handler, utilities
from opencore_legacy_patcher.sys_patch.patchsets.detect import HardwarePatchsetDetection


def _plist_response(payload: dict):
    resp = mock.MagicMock()
    resp.content = plistlib.dumps(payload)
    return resp


def _bytes_response(payload: bytes):
    resp = mock.MagicMock()
    resp.content = payload
    return resp


class TestOSData(unittest.TestCase):

    def test_os_kernel_conversions(self):
        self.assertEqual(int(os_data.os_data.tahoe), 25)
        self.assertEqual(int(os_data.os_data.golden_gate), 27)

        cases = [
            ("10.15.7", 19, "10.15"),
            ("11.7.10", 20, "11"),
            ("13.7", 22, "13"),
            ("14.8", 23, "14"),
            ("15.8.3", 24, "15"),
            ("26.7.3", 25, "26"),
            ("27", 27, "27"),
            ("27.2.1", 27, "27"),
            ("28.0", 28, "28"),
        ]
        for version_str, expected_kernel, expected_os in cases:
            self.assertEqual(os_data.os_conversion.os_to_kernel(version_str), expected_kernel)
            self.assertEqual(os_data.os_conversion.kernel_to_os(expected_kernel), expected_os)

    def test_marketing_names(self):
        self.assertEqual(os_data.os_conversion.convert_kernel_to_marketing_name(25), "Tahoe")
        self.assertEqual(os_data.os_conversion.convert_kernel_to_marketing_name(27), "Golden Gate")
        self.assertEqual(os_data.os_conversion.convert_marketing_name_to_kernel("Golden Gate"), 27)

    def test_build_to_kernel(self):
        self.assertEqual(os_data.os_conversion.build_to_kernel("25G342"), 25)
        self.assertEqual(os_data.os_conversion.build_to_kernel("25G342", "26.7.3"), 25)
        self.assertEqual(os_data.os_conversion.build_to_kernel("26A428"), 27)
        self.assertEqual(os_data.os_conversion.build_to_kernel("26B131"), 27)
        self.assertEqual(os_data.os_conversion.build_to_kernel("26B131", "27.2.1"), 27)
        self.assertEqual(os_data.os_conversion.build_to_kernel("26C5035r", "27.3 beta"), 27)
        self.assertEqual(os_data.os_conversion.build_to_kernel("26B131", "GM"), 27)
        self.assertEqual(os_data.os_conversion.build_to_kernel("26B131", "Unknown"), 27)
        self.assertEqual(os_data.os_conversion.build_to_kernel("26B131", "0.0.0"), 27)
        self.assertEqual(os_data.os_conversion.build_to_kernel("20G1427"), 20)
        self.assertEqual(os_data.os_conversion.build_to_kernel("Unknown"), 0)

    def test_is_os_newer(self):
        self.assertIs(os_data.os_conversion.is_os_newer(25, 0, 27, 0), True)
        self.assertIs(os_data.os_conversion.is_os_newer(27, 0, 25, 0), False)
        self.assertIs(os_data.os_conversion.is_os_newer(27, 0, 27, 1), True)
        self.assertIs(os_data.os_conversion.is_os_newer(27, 1, 27, 0), False)

    def test_recent_releases(self):
        self.assertEqual(
            os_data.os_conversion.recent_releases(os_data.os_data.tahoe),
            [os_data.os_data.ventura, os_data.os_data.sonoma, os_data.os_data.sequoia, os_data.os_data.tahoe],
        )
        self.assertEqual(
            os_data.os_conversion.recent_releases(os_data.os_data.golden_gate),
            [os_data.os_data.sonoma, os_data.os_data.sequoia, os_data.os_data.tahoe, os_data.os_data.golden_gate],
        )


class TestSUCatalogAndAppleDB(unittest.TestCase):

    def test_catalog_urls(self):
        tahoe_url = sucatalog.CatalogURL().url
        self.assertIn("index-26-15-14-13-12-10.16-", tahoe_url)
        self.assertNotIn("index-27-", tahoe_url)

        gg_pub_url = sucatalog.CatalogURL(version=CatalogVersion.GOLDEN_GATE).url
        self.assertIn("index-27-26-15-14-13-12-10.16-", gg_pub_url)

        gg_url = sucatalog.CatalogURL(version=CatalogVersion.GOLDEN_GATE, seed=SeedType.DeveloperSeed).url
        self.assertIn("index-27seed-27-26-15-14-13-12-10.16-", gg_url)

    def _mock_catalog(self):
        def ia_entry(product_id: str, post_date: str):
            return {
                "PostDate": post_date,
                "ExtendedMetaInfo": {"InstallAssistantPackageIdentifiers": {"SharedSupport": f"com.apple.pkg.{product_id}"}},
                "Distributions": {"English": f"https://example.invalid/{product_id}.dist"},
                "Packages": [
                    {
                        "URL": f"https://example.invalid/{product_id}/InstallAssistant.pkg",
                        "Size": 1000,
                        "IntegrityDataURL": f"https://example.invalid/{product_id}/InstallAssistant.pkg.integrityDataV1",
                        "IntegrityDataSize": 100,
                    },
                    {
                        "URL": f"https://example.invalid/{product_id}/com_apple_MobileAsset_MacSoftwareUpdate.plist",
                        "Size": 100,
                    },
                ],
            }

        return {
            "Products": {
                "monterey": ia_entry("monterey", "2024-07-01"),
                "ventura": ia_entry("ventura", "2024-08-01"),
                "sonoma": ia_entry("sonoma", "2025-09-01"),
                "sequoia": ia_entry("sequoia", "2026-01-01"),
                "tahoe": ia_entry("tahoe", "2026-06-01"),
                "gg_unenc": ia_entry("gg_unenc", "2026-10-01"),
                "gg_enc": ia_entry("gg_enc", "2026-11-01"),
            }
        }

    def test_catalog_products_filtering(self):
        assets = {
            "https://example.invalid/monterey/com_apple_MobileAsset_MacSoftwareUpdate.plist": _plist_response({
                "Assets": [{"SupportedDeviceModels": ["VMM-x86_64"], "OSVersion": "12.7.6", "Build": "21H1320"}]
            }),
            "https://example.invalid/ventura/com_apple_MobileAsset_MacSoftwareUpdate.plist": _plist_response({
                "Assets": [{"SupportedDeviceModels": ["VMM-x86_64"], "OSVersion": "13.7.8", "Build": "22H730"}]
            }),
            "https://example.invalid/sonoma/com_apple_MobileAsset_MacSoftwareUpdate.plist": _plist_response({
                "Assets": [{"SupportedDeviceModels": ["VMM-x86_64"], "OSVersion": "14.8", "Build": "23J21"}]
            }),
            "https://example.invalid/sequoia/com_apple_MobileAsset_MacSoftwareUpdate.plist": _plist_response({
                "Assets": [{"SupportedDeviceModels": ["VMM-x86_64"], "OSVersion": "15.8.3", "Build": "24H241"}]
            }),
            "https://example.invalid/tahoe/com_apple_MobileAsset_MacSoftwareUpdate.plist": _plist_response({
                "Assets": [{"SupportedDeviceModels": ["VMM-x86_64", "VMA2MACOSAP"], "OSVersion": "26.7.3", "Build": "25G342"}]
            }),
            "https://example.invalid/gg_unenc/com_apple_MobileAsset_MacSoftwareUpdate.plist": _plist_response({
                "Assets": [{"SupportedDeviceModels": ["VMA2MACOSAP"], "OSVersion": "27.2.1", "Build": "26B131"}]
            }),
            "https://example.invalid/gg_enc/com_apple_MobileAsset_MacSoftwareUpdate.plist": _plist_response({
                "Assets": [{"SupportedDeviceModels": ["VMA2MACOSAP"], "OSVersion": "27.3", "Build": "26C5035r", "_IsEncrypted": True}]
            }),
            "https://example.invalid/gg_enc.dist": _bytes_response(b"<installer-gui-script><title>macOS</title></installer-gui-script>"),
        }

        def fake_get(url, **kwargs):
            return assets.get(url)

        with mock.patch("opencore_legacy_patcher.support.network_handler.NetworkUtilities.get", side_effect=fake_get):
            default_catalog = sucatalog.CatalogProducts(self._mock_catalog())
            self.assertEqual([p["Build"] for p in default_catalog.products], ["21H1320", "22H730", "23J21", "24H241", "25G342"])
            self.assertEqual([p["Build"] for p in default_catalog.latest_products], ["22H730", "23J21", "24H241", "25G342"])

            rd_catalog = sucatalog.CatalogProducts(
                self._mock_catalog(),
                only_vmm_install_assistants=False,
                max_install_assistant_version=CatalogVersion.GOLDEN_GATE,
                allow_encrypted_assets=False,
            )
            rd_products = {p["Build"]: p for p in rd_catalog.products}
            self.assertIn("26B131", rd_products)
            self.assertNotIn("26C5035r", rd_products)
            self.assertEqual(rd_products["26B131"]["InstallAssistant"]["XNUMajor"], 27)
            self.assertEqual(rd_products["26B131"]["Title"], "macOS Golden Gate")
            self.assertEqual(
                [p["Build"] for p in rd_catalog.latest_products],
                ["23J21", "24H241", "25G342", "26B131"],
            )

            enc_catalog = sucatalog.CatalogProducts(
                self._mock_catalog(),
                only_vmm_install_assistants=False,
                max_install_assistant_version=CatalogVersion.GOLDEN_GATE,
                allow_encrypted_assets=True,
            )
            self.assertIn("26C5035r", {p["Build"] for p in enc_catalog.products})

    def test_appledb_products_gating(self):
        fake_feed = [
            {
                "version": "13.7.8",
                "build": "22H730",
                "released": "2024-08-01",
                "deviceMap": ["MacPro7,1"],
                "sources": [{"type": "installassistant", "deviceMap": ["MacPro7,1"], "size": 100, "links": [{"url": "https://example.invalid/13.pkg", "active": True}]}],
            },
            {
                "version": "14.8",
                "build": "23J21",
                "released": "2025-09-01",
                "deviceMap": ["MacPro7,1"],
                "sources": [{"type": "installassistant", "deviceMap": ["MacPro7,1"], "size": 100, "links": [{"url": "https://example.invalid/14.pkg", "active": True}]}],
            },
            {
                "version": "15.8.3",
                "build": "24H241",
                "released": "2026-01-01",
                "deviceMap": ["MacPro7,1"],
                "sources": [{"type": "installassistant", "deviceMap": ["MacPro7,1"], "size": 100, "links": [{"url": "https://example.invalid/15.pkg", "active": True}]}],
            },
            {
                "version": "26.7.3",
                "build": "25G342",
                "released": "2026-06-01",
                "deviceMap": ["MacPro7,1"],
                "sources": [{"type": "installassistant", "deviceMap": ["MacPro7,1"], "size": 100, "links": [{"url": "https://example.invalid/26.pkg", "active": True}]}],
            },
            {
                "version": "27.2.1",
                "build": "26B131",
                "released": "2026-10-01",
                "deviceMap": ["VirtualMac2,1"],
                "sources": [{"type": "installassistant", "deviceMap": ["VirtualMac2,1"], "size": 100, "links": [{"url": "https://example.invalid/27.pkg", "active": True}]}],
            },
        ]
        json_resp = mock.MagicMock()
        json_resp.json.return_value = fake_feed

        with mock.patch("opencore_legacy_patcher.support.network_handler.NetworkUtilities.get", return_value=json_resp), \
             mock.patch("opencore_legacy_patcher.support.network_handler.NetworkUtilities.validate_link", return_value=True):
            c_default = constants.Constants()
            self.assertFalse(c_default.rd_goldengate)
            adb_default = sucatalog.AppleDBProducts(c_default)
            self.assertEqual([p["Build"] for p in adb_default.latest_products], ["22H730", "23J21", "24H241", "25G342"])

            c_rd = constants.Constants()
            c_rd.rd_goldengate = True
            adb_rd = sucatalog.AppleDBProducts(c_rd)
            products_by_build = {p["Build"]: p for p in adb_rd.products}
            self.assertIn("26B131", products_by_build)
            self.assertEqual(products_by_build["26B131"]["InstallAssistant"]["XNUMajor"], 27)
            self.assertEqual(products_by_build["26B131"]["Title"], "macOS Golden Gate")
            self.assertEqual([p["Build"] for p in adb_rd.latest_products], ["23J21", "24H241", "25G342", "26B131"])


class TestInstallerHandlerDetectAndCLI(unittest.TestCase):

    def test_local_installer_list_goldengate(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            apps = Path(tmpdir)
            for app_name, dt_ver, sdk_build in [
                ("Install macOS Golden Gate.app", "27.2.1", "26B131"),
                ("Install macOS Golden Gate GM.app", "GM", "26B131"),
            ]:
                app_dir = apps / app_name / "Contents" / "SharedSupport"
                res_dir = apps / app_name / "Contents" / "Resources"
                app_dir.mkdir(parents=True)
                res_dir.mkdir(parents=True)
                (res_dir / "createinstallmedia").write_bytes(b"")
                with (apps / app_name / "Contents" / "Info.plist").open("wb") as f:
                    plistlib.dump({
                        "DTPlatformVersion": dt_ver,
                        "CFBundleDisplayName": app_name.removesuffix(".app"),
                        "DTSDKBuild": sdk_build,
                        "LSMinimumSystemVersion": "15.0",
                    }, f)
                (app_dir / "SharedSupport.dmg").write_bytes(b"")

            handler = macos_installer_handler.LocalInstallerCatalog.__new__(macos_installer_handler.LocalInstallerCatalog)
            with mock.patch.object(macos_installer_handler, "APPLICATION_SEARCH_PATH", tmpdir), \
                 mock.patch.object(handler, "_parse_sharedsupport_version", return_value=(None, None)):
                listed = handler._list_local_macOS_installers()

            gg_key = apps / "Install macOS Golden Gate.app"
            gg_gm_key = apps / "Install macOS Golden Gate GM.app"
            self.assertEqual(listed[gg_key]["OS"], 27)
            self.assertEqual(listed[gg_gm_key]["OS"], 27)
            self.assertEqual(listed[gg_gm_key]["Version"], "27")

            with mock.patch.object(macos_installer_handler, "APPLICATION_SEARCH_PATH", tmpdir), \
                 mock.patch.object(handler, "_parse_sharedsupport_version", return_value=("26C5035r", "27.3")):
                recomputed = handler._list_local_macOS_installers()
            self.assertEqual(recomputed[gg_gm_key]["OS"], 27)
            self.assertEqual(recomputed[gg_gm_key]["Version"], "27.3")
            self.assertEqual(recomputed[gg_gm_key]["Build"], "26C5035r")

    def test_detect_host_os_gate(self):
        def is_unsupported(xnu_major: int, rd_goldengate: bool) -> bool:
            c = constants.Constants()
            c.rd_goldengate = rd_goldengate
            det = HardwarePatchsetDetection.__new__(HardwarePatchsetDetection)
            det._constants = c
            det._xnu_major = xnu_major
            with mock.patch.object(det, "_dortania_internal_check", return_value=False):
                return det._validation_check_unsupported_host_os()

        self.assertFalse(is_unsupported(25, False))
        self.assertTrue(is_unsupported(26, False))
        self.assertTrue(is_unsupported(27, False))
        self.assertFalse(is_unsupported(25, True))
        self.assertTrue(is_unsupported(26, True))
        self.assertFalse(is_unsupported(27, True))

    def test_cli_rd_goldengate_flag(self):
        with mock.patch.object(sys, "argv", ["OpenCore-Patcher", "--validate"]):
            args = utilities.check_cli_args()
            self.assertIsNotNone(args)
            self.assertFalse(args.rd_goldengate)

        with mock.patch.object(sys, "argv", ["OpenCore-Patcher", "--validate", "--rd_goldengate"]):
            args = utilities.check_cli_args()
            self.assertIsNotNone(args)
            self.assertTrue(args.rd_goldengate)


class TestGoldenGateTools(unittest.TestCase):

    def test_dsc_exports_trie_roundtrip(self):
        from tools.goldengate import dsc_trie

        for n in (0, 1, 127, 128, 16383, 16384, 0x12345678):
            encoded = dsc_trie.encode_uleb(n)
            decoded, end = dsc_trie.parse_uleb(encoded, 0)
            self.assertEqual(decoded, n)
            self.assertEqual(end, len(encoded))

        exports = {
            b"_alpha": ("val", 0, 0x1000),
            b"_alpha_beta": ("val", 0, 0x2040),
            b"_alpha_reexp": ("reexp", 0x08, 3, b"_target_sym"),
            b"_gamma_stub": ("stub", 0x10, 0x3000, 0x4000),
            b"_$s13WindowManager22ExposeGestureAssertionCMn": ("val", 0, 1195352),
        }
        raw = dsc_trie.build_exports_trie(exports)
        self.assertEqual(len(raw) % 8, 0)
        self.assertEqual(dsc_trie.parse_exports_trie(raw), exports)

    def test_codedirectory_16k_slot_rehash(self):
        import hashlib
        import struct
        from tools.goldengate import dsc_trie

        n_slots = 4
        cd_header_len = 44
        hash_off = cd_header_len
        cd_len = hash_off + n_slots * 32
        cd_off = 20
        sb_len = cd_off + cd_len

        sb = bytearray(sb_len)
        struct.pack_into(">III", sb, 0, dsc_trie.CS_MAGIC_EMBEDDED_SIGNATURE, sb_len, 1)
        struct.pack_into(">II", sb, 12, 0, cd_off)
        struct.pack_into(
            ">IIIIIIIII",
            sb,
            cd_off,
            dsc_trie.CS_MAGIC_CODEDIRECTORY,
            cd_len,
            0x20400,
            0,
            hash_off,
            0,
            0,
            n_slots,
            n_slots * dsc_trie.CS_PAGE_SIZE_16K,
        )
        struct.pack_into(">BBBB", sb, cd_off + 36, 32, 2, 0, 14)

        page1 = b"\xAB" * dsc_trie.CS_PAGE_SIZE_16K
        page3 = b"\xCD" * dsc_trie.CS_PAGE_SIZE_16K
        updated = dsc_trie.rehash_codedirectory_slots(sb, {1: page1, 3: page3})

        self.assertEqual(updated[1], hashlib.sha256(page1).digest())
        self.assertEqual(updated[3], hashlib.sha256(page3).digest())
        self.assertEqual(bytes(sb[cd_off + hash_off + 32 : cd_off + hash_off + 64]), updated[1])
        self.assertEqual(bytes(sb[cd_off + hash_off + 96 : cd_off + hash_off + 128]), updated[3])

    def test_sync_coreservices_resources_collect_and_archive(self):
        import tarfile
        from tools.goldengate import sync_coreservices_resources as scr

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "donor"
            sa_base = root / "System/Library/CoreServices/Setup Assistant.app/Contents/Resources/Base.lproj"
            sa_base.mkdir(parents=True)
            (sa_base / "PrivacyController.nib").write_bytes(b"nib1")
            (sa_base / "CreateUserAccountView.nib").write_bytes(b"nib2")
            (sa_base / "ignored.png").write_bytes(b"png")

            finder_res = root / "System/Library/CoreServices/Finder.app/Contents/Resources"
            finder_res.mkdir(parents=True)
            (finder_res / "Localizable.loctable").write_bytes(b"loc")

            ss_res = root / "System/Applications/System Settings.app/Contents/Resources"
            ss_res.mkdir(parents=True)
            (ss_res / "ExtensionDict.xml").write_bytes(b"<plist/>")
            (ss_res / "Sidebar.plist").write_bytes(b"<plist/>")

            out_tgz = Path(tmpdir) / "res.tgz"
            count = scr.build_archive(root, out_tgz)
            self.assertEqual(count, 5)

            with tarfile.open(out_tgz, "r:gz") as tf:
                names = sorted(tf.getnames())
            self.assertEqual(
                names,
                [
                    "System/Applications/System Settings.app/Contents/Resources/ExtensionDict.xml",
                    "System/Applications/System Settings.app/Contents/Resources/Sidebar.plist",
                    "System/Library/CoreServices/Finder.app/Contents/Resources/Localizable.loctable",
                    "System/Library/CoreServices/Setup Assistant.app/Contents/Resources/Base.lproj/CreateUserAccountView.nib",
                    "System/Library/CoreServices/Setup Assistant.app/Contents/Resources/Base.lproj/PrivacyController.nib",
                ],
            )

    def test_menubar_feature_flag_override_plist(self):
        plist_path = Path(__file__).resolve().parent.parent / "tools/goldengate/feature_flags/MenuBar.plist"
        with plist_path.open("rb") as f:
            data = plistlib.load(f)
        self.assertIs(data["MenuBarQFA"]["Enabled"], False)
        self.assertIs(data["LiveActivitiesQFA"]["Enabled"], False)


if __name__ == "__main__":
    unittest.main()
