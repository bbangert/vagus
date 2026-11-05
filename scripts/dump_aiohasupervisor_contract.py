"""Dump every aiohasupervisor model's field list as the JSON
apps/vagus/test/fixtures/aiohasupervisor-<version>-contract.json holds.

Run inside the Core container, whose aiohasupervisor is the one that parses
Vagus's responses (see aiohasupervisor_contract_test.exs for the command).

Every dataclass in the modules is dumped, not only the models the contract
test checks today, so wiring a new endpoint into the test never needs a
second trip to a device.
"""

import dataclasses
import importlib
import inspect
import json
from importlib.metadata import version

MODULES = ["root", "homeassistant", "supervisor", "os", "host", "addons", "network", "mounts", "ingress"]

out = {}
for name in MODULES:
    mod = importlib.import_module("aiohasupervisor.models." + name)
    for cname, cls in inspect.getmembers(mod, inspect.isclass):
        # `__module__` filters out models a module merely imports, which would
        # otherwise appear twice under different keys.
        if dataclasses.is_dataclass(cls) and cls.__module__ == mod.__name__:
            out[f"{name}.{cname}"] = [
                {
                    "n": f.name,
                    "req": f.default is dataclasses.MISSING
                    and f.default_factory is dataclasses.MISSING,
                }
                for f in dataclasses.fields(cls)
            ]
out["_version"] = version("aiohasupervisor")
print(json.dumps(out))
