FILENAME == ARGV[1] {
    if ($0 == "" || $0 ~ /^#/) next
    eq = index($0, "=")
    if (eq == 0) next
    want[substr($0, 1, eq - 1)] = substr($0, eq + 1)
    next
}

{
    raw  = $0
    line = raw
    sub(/^[ \t]+/, "", line)

    if (line ~ /^--/ || line == "" || line ~ /^SandboxVars/) { print raw; next }

    if (match(line, /^[A-Za-z0-9_]+ = \{$/)) {
        name = line
        sub(/ = \{$/, "", name)
        stack[depth++] = name
        print raw
        next
    }

    if (line ~ /^\},?$/) {
        if (depth > 0) depth--
        print raw
        next
    }

    if (match(line, /^[A-Za-z0-9_]+ = /)) {
        eq  = index(line, " = ")
        key = substr(line, 1, eq - 1)

        prefix = ""
        for (i = 0; i < depth; i++) prefix = prefix stack[i] "."
        path = prefix key

        if (path in want) {
            indent = raw
            sub(/[^ \t].*$/, "", indent)
            comma = (raw ~ /,[ \t]*$/) ? "," : ""

            printf "%s%s = %s%s\n", indent, key, want[path], comma
            seen[path] = 1
            next
        }
    }

    print raw
}

END {
    for (path in want)
        if (!(path in seen))
            printf "patch-sandbox: no such setting: %s\n", path > "/dev/stderr"
}
