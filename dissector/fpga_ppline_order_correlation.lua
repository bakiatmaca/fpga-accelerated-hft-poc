if not gui_enabled() then
    return
end

local target_fields = {
    ["itch50.order_ref"] = true,
    ["fpgacustomsignal.oref"] = true,
    ["fix.ClOrdID"] = true,
    ["ouch5.clordid"] = true
}

-- order_sender.c writes the signal OrderRef into the OUCH ClOrdID as 14 decimal
-- digits, zero padded on the left (123456 -> "00000000123456")
local OUCH_CLORDID_LEN = 14

local function normalize_order_ref(value)
    local s = tostring(value)
    if not s:match("^%d+$") then
        return nil
    end
    s = s:gsub("^0+", "")
    return s ~= "" and s or "0"
end

local function show_related_messages(...)
    local order_ref

    for _, field in ipairs({...}) do
        if target_fields[field.name] then
            order_ref = normalize_order_ref(field.value)
            if order_ref then
                break
            end
        end
    end

    if not order_ref then
        report_failure("The selected packet does not contain a usable order reference.")
        return
    end

    local filter = string.format(
        '(itch50.order_ref == %s) or (fpgacustomsignal.oref == %s) or (fix.ClOrdID == "%s")',
        order_ref,
        order_ref,
        order_ref
    )

    -- an OrderRef longer than 14 digits never becomes an OUCH order (order_sender.c skips it)
    if #order_ref <= OUCH_CLORDID_LEN then
        filter = filter .. string.format(
            ' or (ouch5.clordid == "%s")',
            string.rep("0", OUCH_CLORDID_LEN - #order_ref) .. order_ref
        )
    end

    set_filter(filter)
    apply_filter()
end

register_packet_menu("FPGA-Accl pipeline Correlation/Show Related Messages", show_related_messages)

