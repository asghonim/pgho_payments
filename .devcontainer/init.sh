set -euo pipefail

curl -fsSL https://raw.githubusercontent.com/supabase/cli/main/install | bash

DBDEV_DEB=/tmp/dbdev.deb
DBDEV_SHA256=d3aca68584f402c2192d2946acdd081a189851505be38ceaee6418340a335b11

curl -fsSL -o "$DBDEV_DEB" https://github.com/supabase/dbdev/releases/download/v0.1.7/dbdev-v0.1.7-linux-amd64.deb
echo "$DBDEV_SHA256  $DBDEV_DEB" | sha256sum -c -
sudo dpkg -i "$DBDEV_DEB"
rm "$DBDEV_DEB"