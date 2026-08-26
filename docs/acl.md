# ACL (Access Control)

Bonodis supports per-user access control. Users have passwords and command permissions.

## ACL file

Create a `users.acl` file:

```
user default on >defaultpass +@all
user readonly on >readpass +@read -@write -@admin
user admin on >adminpass +@all
```

Start with:

```
bonodis --aclfile users.acl --bind 127.0.0.1
```

## ACL file format

Each line:

```
user <name> <on|off> [nopass|>password] [+@all|+@read|+@write|+@admin|+cmd|-cmd]
```

| Token | Meaning |
| --- | --- |
| `on` / `off` | User is enabled / disabled |
| `nopass` | No password required |
| `>password` | Set the password |
| `+@all` | Allow all commands |
| `+@read` | Allow read commands |
| `+@write` | Allow write commands |
| `+@admin` | Allow admin commands (CONFIG, FLUSHALL, etc.) |
| `+cmd` | Allow a specific command |
| `-cmd` | Deny a specific command |

## Authenticating

```
bonodis-cli -u admin -a adminpass PING
# PONG

bonodis-cli -u readonly -a readpass SET k v
# NOPERM this user has no permissions to run the 'set' command

bonodis-cli -u readonly -a readpass GET k
# (value)
```

Or with `AUTH`:

```
AUTH admin adminpass
# OK
```

## Runtime management

```
ACL WHOAMI
# "admin"

ACL LIST
# user default on >defaultpass +@all
# user readonly on >readpass +@read

ACL GETUSER readonly
# (user details)

ACL SETUSER writer on >writerpass +@write
ACL SAVE     # write back to the acl file
ACL LOAD     # reload from the acl file
```

## The default user

When `--requirepass secret` is set without an ACL file, all clients authenticate as the `default` user with `+@all` permissions. The password from `--requirepass` is the default user's password.

When an ACL file is loaded, `--requirepass` is ignored. The `default` user in the file takes precedence.

## Differences from Redis ACL

Bonodis ACL is simpler:

- No command selectors (`+GET|SET` syntax)
- No key patterns (`~key:*`)
- No channel restrictions
- Categories are `@all`, `@read`, `@write`, `@admin` only
- File format is Bonodis-specific, not Redis ACL format
