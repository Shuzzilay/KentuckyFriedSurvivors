
FILENAME == ARGV[1] {
    if ($0 == "" || $0 ~ /^#/) next
    eq = index($0, "=")
    if (eq == 0) next
    key = substr($0, 1, eq - 1)
    want[tolower(key)] = substr($0, eq + 1)
    next
}

{
    eq = index($0, "=")

    if (eq == 0 || $0 ~ /^[ \t]*#/) { print; next }

    key = substr($0, 1, eq - 1)
    lk  = tolower(key)

    if (lk in want) {
        print key "=" want[lk]
        seen[lk] = 1
        next
    }

    print
}

END {
    for (k in want)
        if (!(k in seen))
            printf "patch-ini: no such setting: %s\n", k > "/dev/stderr"
}
