panel = {
    name = "Node.js",
    interval = 3,
    position = "right",
    color = "green"
}

function collect(data)
    local lines = {}
    local count = 0
    local total_mem = 0
    local total_cpu = 0

    for _, p in ipairs(data.processes) do
        if string.find(p.name:lower(), "node") then
            count = count + 1
            total_mem = total_mem + p.mem
            total_cpu = total_cpu + p.cpu
        end
    end

    if count > 0 then
        table.insert(lines, {text = count .. " processes", color = "green"})
        table.insert(lines, {text = string.format("CPU: %.1f%%", total_cpu), color = "yellow"})
        table.insert(lines, {text = string.format("Mem: %.0f MiB", total_mem / 1048576)})
    else
        table.insert(lines, {text = "No Node processes", color = "gray"})
    end

    return lines
end
