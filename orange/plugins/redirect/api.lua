local API = {}
local table_insert = table.insert
local ipairs = ipairs
local type = type
local tostring = tostring
local cjson = require("cjson")
local utils = require("orange.utils.utils")
local orange_db = require("orange.store.orange_db")

API["/redirect/enable"] = {
    POST = function(store)
        local store_type = store.store_type

        return function(req, res, next)
            local enable = req.body.enable
            if enable == "1" then enable = true else enable = false end

            local result = false
            if store_type == "file" then
                local redirect_config = store:get("redirect_config") or {}
                redirect_config.enable = enable
                store:set("redirect_config", redirect_config)
                result = store:store()
            elseif store_type == "mysql" then
                local redirect_enable = "0"
                if enable then redirect_enable = "1" end
                local update_result = store:update({
                    sql = "replace into meta SET `key`=?, `value`=?",
                    params = { "redirect.enable", redirect_enable }
                })

                if update_result then
                    local success, err, forcible = orange_db.set("redirect.enable", enable)
                    result = success
                else
                    result = false
                end
            end

            if result then
                res:json({
                    success = true,
                    msg = (enable == true and "开启redirect成功" or "关闭redirect成功")
                })
            else
                res:json({
                    success = false,
                    data = (enable == true and "开启redirect失败" or "关闭redirect失败")
                })
            end
        end
    end
}

API["/redirect/fetch_config"] = {
    -- fetch data from db
    GET = function(store)
        local store_type = store.store_type

        return function(req, res, next)
            local success, data = false, {}
            if store_type == "file" then
                success = true
                data = store:get("divide_config") or { enable = false, rules = {} }
            elseif store_type == "mysql" then
                -- 查找enable
                local enable, err1 = store:query({
                    sql = "select `value` from meta where `key`=?",
                    params = { "redirect.enable" }
                })

                if err1 then
                    return res:json({
                        success = false,
                        msg = "get enable error"
                    })
                end

                if enable and type(enable) == "table" and #enable == 1 and enable[1].value == "1" then
                    data.enable = true
                else
                    data.enable = false
                end

                -- 查找rules
                local rules, err2 = store:query({
                    sql = "select `value` from redirect order by id asc"
                })
                if err2 then
                    return res:json({
                        success = false,
                        msg = "get rules error"
                    })
                end

                if rules and type(rules) == "table" and #rules > 0 then
                    local format_rules = {}
                    for i, v in ipairs(rules) do
                        table_insert(format_rules, cjson.decode(v.value))
                    end
                    data.rules = format_rules
                    success = true
                else
                    success = true
                    data.rules = {}
                end
            end

            res:json({
                success = success,
                data = data
            })
        end
    end,
}

API["/redirect/sync"] = {
    -- update the local cache to data stored in db
    POST = function(store)
        local store_type = store.store_type

        return function(req, res, next)
            local success, data = false, {}
            if store_type == "file" then
                success = true
            elseif store_type == "mysql" then
                -- 查找enable
                local enable, err1 = store:query({
                    sql = "select `value` from meta where `key`=?",
                    params = { "redirect.enable" }
                })

                if err1 then
                    return res:json({
                        success = false,
                        msg = "get enable error"
                    })
                end

                if enable and type(enable) == "table" and #enable == 1 and enable[1].value == "1" then
                    data.enable = true
                else
                    data.enable = false
                end

                -- 查找rules
                local rules, err2 = store:query({
                    sql = "select `value` from redirect order by id asc"
                })
                if err2 then
                    return res:json({
                        success = false,
                        msg = "get rules error"
                    })
                end

                if rules and type(rules) == "table" and #rules > 0 then
                    local format_rules = {}
                    for i, v in ipairs(rules) do
                        table_insert(format_rules, cjson.decode(v.value))
                    end
                    data.rules = format_rules
                else
                    data.rules = {}
                end


                local ss, err3, forcible = orange_db.set("redirect.enable", data.enable)
                if not ss or err3 then
                    return res:json({
                        success = false,
                        msg = "update local enable error"
                    })
                end
                ss, err3, forcible = orange_db.set_json("redirect.rules", data.rules)
                if not ss or err3 then
                    return res:json({
                        success = false,
                        msg = "update local rules error"
                    })
                end

                success = true
            end

            res:json({
                success = success
            })
        end
    end,
}

API["/redirect/configs"] = {
    GET = function(store)
        local store_type = store.store_type

        return function(req, res, next)
            local success, data = false, {}
            if store_type == "file" then
                success = true
                data = store:get("redirect_config") or { enable = false, rules = {} }
            elseif store_type == "mysql" then
                data.enable = orange_db.get("redirect.enable")
                data.rules = orange_db.get_json("redirect.rules")
                success = true
            end

            res:json({
                success = success,
                data = data
            })
        end
    end,

    -- new
    PUT = function(store)
        local store_type = store.store_type

        return function(req, res, next)
            local rule = req.body.rule
            rule = cjson.decode(rule)
            rule.id = utils.new_id()
            rule.time = utils.now()

            local success, data = false, {}
            if store_type == "file" then
                -- check
                local redirect_config = store:get("redirect_config") or { enable = false, rules = {} }
                redirect_config.rules = redirect_config.rules or {}
                table_insert(redirect_config.rules, rule)

                -- save to file
                store:set("redirect_config", redirect_config)
                success = store:store()
                data = redirect_config
            elseif store_type == "mysql" then
                -- 插入到mysql
                local insert_result = store:insert({
                    sql = "insert into redirect(`key`, `value`) values(?,?)",
                    params = { rule.id, cjson.encode(rule) }
                })

                -- 插入成功，则更新本地缓存
                if insert_result then
                    local redirect_rules = orange_db.get_json("redirect.rules") or {}
                    table_insert(redirect_rules, rule)
                    local s, err, forcible = orange_db.set_json("redirect.rules", redirect_rules)
                    if s then
                        success = true
                        data.rules = redirect_rules
                        data.enable = orange_db.get("redirect.enable")
                    else
                        ngx.log(ngx.ERR, "save redirect rules locally error: ", err)
                    end
                else
                    success = false
                end
            end

            res:json({
                success = success,
                data = data
            })
        end
    end,
    DELETE = function(store)
        local store_type = store.store_type
        return function(req, res, next)
            local rule_id = tostring(req.body.rule_id)
            if not rule_id or rule_id == "" then
                return res:json({
                    success = false,
                    msg = "error param: rule id shoule not be null."
                })
            end


            if store_type == "file" then
                -- check
                local redirect_config = store:get("redirect_config")
                local old_rules = redirect_config.rules
                local new_rules = {}
                for i, v in ipairs(old_rules) do
                    if v.id ~= rule_id then
                        table_insert(new_rules, v)
                    end
                end
                redirect_config.rules = new_rules

                -- save to file
                store:set("redirect_config", redirect_config)
                local store_result = store:store()

                if store_result == true then
                    res:json({
                        success = true,
                        data = redirect_config
                    })
                else
                    redirect_config.rules = old_rules
                    res:json({
                        success = false,
                        data = redirect_config
                    })
                end
            elseif store_type == "mysql" then
                local delete_result = store:delete({
                    sql = "delete from redirect where `key`=?",
                    params = { rule_id }
                })

                if delete_result then
                    local old_rules = orange_db.get_json("redirect.rules") or {}
                    local new_rules = {}
                    for i, v in ipairs(old_rules) do
                        if v.id ~= rule_id then
                            table_insert(new_rules, v)
                        end
                    end
                    local success, err, forcible = orange_db.set_json("redirect.rules", new_rules)
                    if err or forcible then
                        ngx.log(ngx.ERR, "update local rules error when deleting:", err, ":", forcible)
                        return res:json({
                            success = false,
                            msg = "update local rules error when deleting"
                        })
                    end

                    res:json({
                        success = success,
                        data = {
                            rules = new_rules,
                            enable = orange_db.get("redirect.enable")
                        }
                    })
                else
                    res:json({
                        success = false,
                        msg = "delete rule from db error"
                    })
                end
            end
        end
    end,
    -- modify
    POST = function(store)
        local store_type = store.store_type
        return function(req, res, next)
            local rule = req.body.rule
            rule = cjson.decode(rule)


            if store_type == "file" then
                -- check
                local redirect_config = store:get("redirect_config")
                local old_rules = redirect_config.rules
                local new_rules = {}
                for i, v in ipairs(old_rules) do
                    if v.id == rule.id then
                        rule.time = utils.now()
                        table_insert(new_rules, rule)
                    else
                        table_insert(new_rules, v)
                    end
                end
                redirect_config.rules = new_rules

                -- save to file
                store:set("redirect_config", redirect_config)
                local store_result = store:store()

                if store_result == true then
                    res:json({
                        success = true,
                        data = redirect_config
                    })
                else
                    redirect_config.rules = old_rules
                    res:json({
                        success = false,
                        data = redirect_config
                    })
                end
            elseif store_type == "mysql" then
                local update_result = store:delete({
                    sql = "update redirect set `value`=? where `key`=?",
                    params = { cjson.encode(rule), rule.id }
                })

                if update_result then
                    local old_rules = orange_db.get_json("redirect.rules") or {}
                    local new_rules = {}
                    for i, v in ipairs(old_rules) do
                        if v.id == rule.id then
                            rule.time = utils.now()
                            table_insert(new_rules, rule)
                        else
                            table_insert(new_rules, v)
                        end
                    end

                    local success, err, forcible = orange_db.set_json("redirect.rules", new_rules)
                    if err or forcible then
                        ngx.log(ngx.ERR, "update local rules error when modifing:", err, ":", forcible)
                        return res:json({
                            success = false,
                            msg = "update local rules error when modifing"
                        })
                    end

                    res:json({
                        success = success,
                        data = {
                            rules = new_rules,
                            enable = orange_db.get("redirect.enable")
                        }
                    })

                else
                    res:json({
                        success = false,
                        msg = "update rule to db error"
                    })
                end
            end
        end
    end
}

return API