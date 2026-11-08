"""Print a bcrypt hash for a password, for the app_user rows in 03_seed.sql.

Usage (inside the .venv):
    python3 generator/hash_password.py 'Admin@App123'

The database never stores the password itself, only this hash
(chk_app_user_hash insists on at least 50 characters; bcrypt gives 60).
The "2a" prefix is the bcrypt variant every Node.js library can verify (Step 8).
"""
import sys

import bcrypt

if len(sys.argv) != 2:
    sys.exit("usage: python3 generator/hash_password.py '<password>'")

hashed = bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=10, prefix=b"2a"))
print(hashed.decode())
