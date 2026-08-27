#!/usr/bin/env python3
from pathlib import Path


def replace_exact(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"{path}: x64 patch point not found: {label}")
    path.write_text(text.replace(old, new), encoding="utf-8")


root = Path(__file__).resolve().parent.parent

device = root / "src/d3d9fe/d9mt_device.cpp"
instance = root / "src/d3d9fe/d9mt_instance.cpp"

# Vulkan uses pointer typedefs for non-dispatchable handles on 64-bit targets.
# The d9mt fake backend only needs unique opaque cookies, so convert the integer
# cookie through uintptr_t instead of assigning it directly as the i686 build
# does.
replace_exact(
    device,
    "      *pSetLayout = ++g_fakeCookie;",
    "      *pSetLayout = reinterpret_cast<VkDescriptorSetLayout>(static_cast<uintptr_t>(++g_fakeCookie));",
    "VkDescriptorSetLayout cookie",
)
replace_exact(
    device,
    "      *pTemplate = ++g_fakeCookie;",
    "      *pTemplate = reinterpret_cast<VkDescriptorUpdateTemplate>(static_cast<uintptr_t>(++g_fakeCookie));",
    "VkDescriptorUpdateTemplate cookie",
)
replace_exact(
    device,
    "      *pPipelineLayout = ++g_fakeCookie;",
    "      *pPipelineLayout = reinterpret_cast<VkPipelineLayout>(static_cast<uintptr_t>(++g_fakeCookie));",
    "VkPipelineLayout cookie",
)
replace_exact(
    device,
    "    pool.pool    = ++d9mt::g_fakeCookie;",
    "    pool.pool    = reinterpret_cast<VkQueryPool>(static_cast<uintptr_t>(++d9mt::g_fakeCookie));",
    "VkQueryPool cookie",
)

replace_exact(
    instance,
    "      *pSurface = static_cast<VkSurfaceKHR>(\n        reinterpret_cast<uintptr_t>(pCreateInfo->hwnd));",
    "      *pSurface = reinterpret_cast<VkSurfaceKHR>(\n        reinterpret_cast<uintptr_t>(pCreateInfo->hwnd));",
    "VkSurfaceKHR HWND handle",
)

print("[x64] patched fake Vulkan non-dispatchable handles for Win64")
