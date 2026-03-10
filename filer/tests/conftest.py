"""
Set up dummy environment variables before filer.app is imported.
The module-level `app = create_app()` needs these to exist.
"""

import os
import tempfile

_secrets_dir = tempfile.mkdtemp()


def _write_secret(name: str, value: str) -> str:
    path = os.path.join(_secrets_dir, name)
    with open(path, "w") as fh:
        fh.write(value)
    return path


os.environ.setdefault("FILER_SECRET_FILE", _write_secret("filer_secret.txt", "test-secret"))
os.environ.setdefault("STORAGE_BOX_URL", "https://u000000.your-storagebox.de")
os.environ.setdefault("STORAGE_BOX_USER", "u000000")
os.environ.setdefault(
    "STORAGE_BOX_PASSWORD_FILE", _write_secret("storage_box_password.txt", "test-password")
)
