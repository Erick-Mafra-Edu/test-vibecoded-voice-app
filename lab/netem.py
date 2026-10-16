"""Destination-specific UDP egress impairment; signaling TCP is untouched."""
import asyncio
import ipaddress

PROFILES = {"clear": [], "blocked": ["loss", "100%"], "degraded": ["delay", "80ms", "35ms", "loss", "12%"], "slow": ["delay", "120ms", "20ms", "loss", "5%"], "reorder": ["delay", "20ms", "10ms", "reorder", "20%", "duplicate", "2%"], "bandwidth": ["rate", "64kbit"]}


async def run(*args, allow_failure=False):
    process = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    _, error = await process.communicate()
    if process.returncode and not allow_failure:
        raise RuntimeError(error.decode())


async def configure(destination, profile):
    address = str(ipaddress.IPv4Address(destination))
    if profile not in PROFILES:
        raise ValueError("unknown impairment")
    await run("tc", "qdisc", "del", "dev", "eth0", "root", allow_failure=True)
    if profile == "clear":
        return
    await run("tc", "qdisc", "add", "dev", "eth0", "root", "handle", "1:", "prio")
    await run("tc", "qdisc", "add", "dev", "eth0", "parent", "1:3", "handle", "30:", "netem", *PROFILES[profile])
    await run("tc", "filter", "add", "dev", "eth0", "protocol", "ip", "parent", "1:", "prio", "1", "u32", "match", "ip", "dst", address + "/32", "match", "ip", "protocol", "17", "0xff", "flowid", "1:3")
