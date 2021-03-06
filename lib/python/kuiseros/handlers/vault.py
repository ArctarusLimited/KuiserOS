import io
import os
import tempfile
import subprocess

import fabric
import hvac, hvac.exceptions

from kuiseros.utils import logger
from kuiseros.machine import Machine
from kuiseros.handlers.base import BaseHandler

# modified from https://github.com/fabric/fabric/issues/1750#issuecomment-389990692
def _root_install(
    connection: fabric.Connection,
    source: str,
    dest: str,
    *,
    owner: str = "root",
    group: str = "root",
    mode: str = "0600",
):
    """
    Helper which installs a file with arbitrary permissions and ownership

    This is a replacement for Fabric 1's `put(…, use_sudo=True)` and adds the
    ability to set the expected ownership and permissions in one operation.
    """

    # make sure we umask correctly to avoid making the temp file world readable
    with connection.prefix("umask 077"):
        mktemp_result = connection.run("mktemp", hide="out")

    assert mktemp_result.ok
    temp_file = mktemp_result.stdout.strip()

    try:
        connection.put(source, temp_file)
        connection.run(
            f"doas install -o {owner} -g {group} -m {mode} {temp_file} {dest}"
        )
    finally:
        connection.run(f"rm {temp_file}")


class VaultHandler(BaseHandler):
    """
    Handler for configuring and uploading vault approles and keys
    """

    def __init__(self):
        self._client = self._get_client()

    def _get_client(self) -> hvac.Client:
        """
        Attempts to perform basic validation on the client
        """
        client = hvac.Client(verify=os.getenv("VAULT_CACERT"))

        if not client.token:
            logger.debug("No Vault token provided. Key upload will be skipped.")
            return None

        try:
            client.lookup_token(client.token)
        except Exception:
            logger.error("Failed to authenticate to Vault with the provided token. Keys will not be uploaded.")
            return None

        return client

    def _ensure_approle(self, id: str, config: dict) -> str:
        name = f"kos_automatic.{id}"

        policies = ["default"]
        policies.extend(config["policies"])

        try:
            logger.debug(f"Provisioning Vault AppRole {name}")

            self._client.auth.approle.create_or_update_approle(
                role_name=name,
                token_policies=policies,

                # TODO: implement this
                # token_bound_cidrs=[""],
            )
        except Exception:
            logger.error(f"Failed to create AppRole {name}")
            return None

        return name

    def _push_approle(self, conn: fabric.Connection, role: str):
        # Read the role ID and secret ID from Vault
        prefix = f"auth/approle/role/{role}"
        result = self._client.read(f"{prefix}/role-id")
        if not result:
            raise Exception(f"Approle not found: {role}")

        role_id = result["data"]["role_id"]
        secret_id = self._client.write(f"{prefix}/secret-id")["data"]["secret_id"]

        # Ensure /var/lib/vault-agent exists and is owned by the correct user
        conn.run("doas mkdir -p /var/lib/vault-agent")
        conn.run("doas chmod 0700 /var/lib/vault-agent")
        conn.run("doas chown vault-agent:vault-agent /var/lib/vault-agent")

        # Copy the files
        _root_install(
            conn,
            io.StringIO(role_id),
            "/var/lib/vault-agent/role-id",
            owner="vault-agent",
            group="vault-agent",
            mode="0600",
        )
        _root_install(
            conn,
            io.StringIO(secret_id),
            "/var/lib/vault-agent/secret-id",
            owner="vault-agent",
            group="vault-agent",
            mode="0600",
        )

    def _push_template(self, conn: fabric.Connection, id: str, text: str, folder: str):
        data: bytes

        # Evaluate using consul-template
        with tempfile.NamedTemporaryFile() as f:
            with open(f.name, "wb") as obj:
                obj.write(text.encode())

            result = subprocess.run(
                ["consul-template", "-template", f"{f.name}:{f.name}", "-once"],
                capture_output=True,
            )
            result.check_returncode()

            with open(f.name, "rb") as obj:
                data = obj.read().strip()

        _root_install(
            conn,
            io.BytesIO(data),
            f"{folder}/.{id}.tmp",
            owner="vault-agent",
            group="vault-agent",
            mode="0600",
        )

    def _push_keys(self, conn: fabric.Connection, keys: dict):
        for key in keys.values():
            if not key["external"]:
                continue

            # are we overridden with a custom template?
            if key["template"]:
                self._push_template(conn, key["name"], key["template"], key["folder"])
                continue

            # regular template logic
            for template in key["templates"]:
                self._push_template(
                    conn, template["id"], template["text"], key["folder"]
                )

        logger.debug(f"{len(keys)} keys deployed")

    def run(self, machine: Machine):
        if not self._client:
            return

        config = machine.config.get("vault", {})
        if not config["appRole"]["enable"]:
            return

        logger.debug(f"Updating Vault configuration for {machine.id}")

        # If we don't have an approle name, we'll provision it ourselves
        role = config["appRole"]["name"]
        if not role:
            role = self._ensure_approle(machine.id, config["appRole"])

        # Approle creation failed?
        if not role:
            return

        self._push_approle(machine.conn, role)
        self._push_keys(machine.conn, config["keys"])
