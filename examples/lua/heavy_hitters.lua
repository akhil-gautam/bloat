panel = {
    name = "Heavy Hitters",
    interval = 2,
    position = "left",
    color = "red"
}

function collect(data)
    local lines = {}
    local threshold = 50.0  -- CPU%

    for _, p in ipairs(data.processes) do
        if p.cpu > threshold then
            table.insert(lines, {
                text = string.format("%s (PID %d): %.1f%%", p.name, p.pid, p.cpu),
                color = "red",
                bold = true
            })
        end
    end

    if #lines == 0 then
        table.insert(lines, {text = "All quiet", color = "green"})
    end

    return lines
end
