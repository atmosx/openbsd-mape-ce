#!/bin/sh
set -eu

src=${1:-/usr/src}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mape-pf-validate.XXXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/test.c" <<'EOF'
#include <sys/types.h>
#include <assert.h>
#include <errno.h>
#include <stdint.h>
EOF

awk '
/^struct pf_mape_port \{/ { active = 1 }
active { print }
active && /^};/ { found = 1; exit }
END { if (!found) exit 1 }
' "$src/sys/net/pfvar.h" >> "$tmp/test.c"

awk '
/^pf_mape_validate\(/ { active = 1; print "static int" }
active { print }
active && /^}/ { found = 1; exit }
END { if (!found) exit 1 }
' "$src/sys/net/pf_ioctl.c" >> "$tmp/test.c"

cat >> "$tmp/test.c" <<'EOF'
int
main(void)
{
	struct pf_mape_port mape = {0};
	unsigned a, k, psid, valid;

	assert(pf_mape_validate(&mape) == 0);
	for (a = 0; a <= UINT8_MAX; a++) {
		for (k = 0; k <= UINT8_MAX; k++) {
			for (psid = 0; psid <= UINT16_MAX; psid += UINT16_MAX) {
				mape.offset = a;
				mape.psidlen = k;
				mape.psid = psid;
				valid = a == 0 && k == 0 && psid == 0;
				if (a >= 1 && a <= 15 && k >= 1 && k <= 16 - a)
					valid = psid < (1U << k);
				assert(pf_mape_validate(&mape) == (valid ? 0 : EINVAL));
			}
			if (a >= 1 && a <= 15 && k >= 1 && k <= 16 - a) {
				mape.psid = (1U << k) - 1;
				assert(pf_mape_validate(&mape) == 0);
				mape.psid++;
				assert(pf_mape_validate(&mape) == EINVAL);
			}
		}
	}
	return (0);
}
EOF

${CC:-cc} ${CFLAGS:-} -Wall -Wextra -o "$tmp/test" "$tmp/test.c"
"$tmp/test"
printf '%s\n' 'ok - kernel MAP-E parameter validation'
