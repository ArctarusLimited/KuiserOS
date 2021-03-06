import os
import json
import icmplib
import subprocess
from pathlib import Path
from ipaddress import IPv6Address
from typing import List, Set, Mapping

from kuiseros.utils import logger
from kuiseros.machine import Machine, LivenessStat
from kuiseros.handlers.vault import VaultHandler

HANDLER_CLASSES = [VaultHandler]


def _is_host_wsl() -> bool:
    """
    Whether the host machine is running under WSL
    """
    with open("/proc/version", "r") as f:
        version = f.read()
    if "microsoft-standard-WSL2" in version:
        return True
    return False

IS_HOST_WSL = _is_host_wsl()


class DeploymentUnit:
    """
    Represents a "deployment unit" capable of deploying collections of machines
    """

    def __init__(self, flake: str, path: str = None, show_trace: bool = False):
        self._flake = flake
        self._path = path
        self._machines: Mapping[str, Machine] = None
        self._reachability: Mapping[str, bool] = None

        self._handlers = [i() for i in HANDLER_CLASSES]
        self._show_trace = show_trace

    def _call_colmena(self, command: str, args: List[str] = [], pipe: bool = True):
        params = ["colmena", command]
        params += args

        nix_params = []
        nix_params.extend(["--quiet", "--quiet"])
        if self._show_trace:
            nix_params.append("--show-trace")

        extra = {}
        if pipe:
            extra["stdout"] = subprocess.PIPE

        extra["env"] = os.environ
        extra["env"]["COLMENA_NIX_ARGS"] = " ".join(nix_params)

        result = subprocess.run(params, **extra)
        result.check_returncode()
        return result

    @property
    def machines(self) -> Mapping[str, Machine]:
        """
        Returns an attribute set of all machines in the unit
        """
        if self._machines:
            return self._machines

        self._machines = {}

        cur = Path(__file__).parent.joinpath("eval.nix")
        with open(cur, "r") as f:
            eval_nix = f.read()
        result = self._call_colmena("eval", ["-E", eval_nix])
        config = json.loads(result.stdout)

        for k, v in config.items():
            self._machines[k] = Machine(k, v)

        return self._machines

    @property
    def reachability(self) -> Mapping[str, LivenessStat]:
        """
        Returns the ICMP reachability of all machines
        """
        if self._reachability:
            return self._reachability

        addrs = [
            [v.id, v.ip] for v in self.machines.values()
            if v.ip and (isinstance(v.ip, IPv6Address) and not IS_HOST_WSL)
        ]

        hosts: List[icmplib.Host] = icmplib.multiping(
            [str(v[1]) for v in addrs], count=1, timeout=1, privileged=False
        )

        results = {v.id: LivenessStat() for v in self.machines.values()}
        for i, host in enumerate(hosts):
            results[addrs[i][0]] = LivenessStat(host)

        self._reachability = results
        return results

    def deploy(self, hosts: Set[str], post_only: bool = False):
        for m in hosts:
            if m not in self.machines.keys():
                raise Exception(f"The machine {m} does not exist!")

        args = []

        machines = self.machines
        if len(hosts) > 0:
            machines = {k: v for k, v in self.machines.items() if k in hosts}
            args += ["--on", ",".join(machines)]

        # safety check if deploying more than one machine
        if len(machines) > 1:
            print(f"{len(machines)} machine(s) will be deployed:")
            for m in machines.values():
                print(f"    {m.id}")
            resp = str(input("Continue? Y/n: ")).strip()
            if resp[0] != "Y":
                print("Aborting.")
                return

        if not post_only:
            logger.info("Running deployment...")
            self._call_colmena("apply", args, False)

        # run post-deploy actions
        logger.info("Running post-deploy actions...")
        for m in machines.values():
            for h in self._handlers:
                h.run(m)
