local domain = os.getenv("PROSODY_DOMAIN") or "example.com"
local admin_jid = os.getenv("PROSODY_ADMIN_JID") or ("admin@" .. domain)
local db_name = os.getenv("PROSODY_DB_NAME") or "prosody"
local db_user = os.getenv("PROSODY_DB_USER") or "prosody"
local db_host = os.getenv("PROSODY_DB_HOST") or "postgres"
local db_password_file = os.getenv("PROSODY_DB_PASSWORD_FILE") or "/run/secrets/postgres_password"
local filer_secret_file = os.getenv("PROSODY_FILER_SECRET_FILE") or "/run/secrets/filer_secret"
local upload_base_url = os.getenv("PROSODY_UPLOAD_BASE_URL") or ""
local upload_max_bytes = tonumber(os.getenv("PROSODY_UPLOAD_MAX_BYTES")) or (20 * 1024 * 1024)
local turn_secret_file = os.getenv("PROSODY_TURN_SECRET_FILE") or "/run/secrets/turn_secret"
local turn_host = os.getenv("PROSODY_TURN_HOST") or ""

local function read_secret(path)
    local file = io.open(path, "r")
    if not file then
        return nil, "cannot open secret file"
    end
    local value = file:read("*a") or ""
    file:close()
    value = value:gsub("%s+$", "")
    if value == "" then
        return nil, "secret file is empty"
    end
    return value
end

local db_password, db_password_err = read_secret(db_password_file)
if not db_password then
    error("Failed to read database password from " .. db_password_file .. ": " .. db_password_err)
end

local filer_secret, filer_secret_err = read_secret(filer_secret_file)
if not filer_secret then
    error("Failed to read filer secret from " .. filer_secret_file .. ": " .. filer_secret_err)
end

local turn_secret, turn_secret_err = read_secret(turn_secret_file)
if not turn_secret then
    error("Failed to read TURN secret from " .. turn_secret_file .. ": " .. turn_secret_err)
end

admins = { admin_jid }

plugin_paths = { "/etc/prosody/modules" }

modules_enabled = {
    "roster";
    "saslauth";
    "tls";
    "dialback";
    "disco";
    "carbons";
    "pep";
    "private";
    "blocklist";
    "vcard4";
    "vcard_legacy";
    "mam";
    "smacks";
    "limits";
    "http_upload_external";
    "external_services";
}

http_upload_external_base_url = upload_base_url

http_upload_external_secret = filer_secret
http_upload_external_file_size_limit = upload_max_bytes

external_services = {
    { type = "stun"; host = turn_host; port = 3478; };
    { type = "turn"; host = turn_host; port = 3478; transport = "udp";
      secret = turn_secret; ttl = 86400; algorithm = "turn"; };
    { type = "turn"; host = turn_host; port = 3478; transport = "tcp";
      secret = turn_secret; ttl = 86400; algorithm = "turn"; };
}

c2s_require_encryption = true
allow_unencrypted_plain_auth = false
s2s_secure_auth = true
archive_expires_after = "30d"

limits = {
    c2s = {
        rate = "10kb/s";
        burst = "100kb";
    };
    s2sin = {
        rate = "30kb/s";
    };
}

storage = "sql"

sql = {
    driver = "PostgreSQL";
    database = db_name;
    username = db_user;
    password = db_password;
    host = db_host;
}

VirtualHost(domain)
    ssl = {
        certificate = "/etc/prosody/certs/" .. domain .. "/certificate.crt";
        key = "/etc/prosody/certs/" .. domain .. "/privatekey.key";
    }
