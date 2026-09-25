--[[
	ability_item_usage_generic.lua
	================================
	Generic (hero-agnostic) ability & item usage logic for the Dota 2 bot
	framework (Yours Blog / OpenDota-style bot script).

	This module is loaded for every hero. It:
	  1. Identifies the controlled bot and the hero-specific script under
	     BotsLib/ (e.g. BotsLib/hero_nevermore.lua).
	  2. Pulls the hero's ability/item build tables (bDeafaultAbility,
	     bDeafaultItem, sSkillList) and runtime skill list.
	  3. Exposes the public API consumed by the bot brain:
	     ConsiderAbilityUse / UseAbility / ConsiderItemUse / UseItem /
	     CourierUsageThink / and the various Item*es helpers.
	  4. Provides shared helpers: dispel handling, base-location vectors,
	     Kez ability-swap mapping, and hero-script reloading.

	Most single-letter locals used throughout the original obfuscated file
	have been renamed to meaningful identifiers by deobfuscate.py.
--]]

-- Module table: the public API returned to the bot brain for this hero.
local abilityItemUsage = {}

-- The bot we are controlling this frame, plus its unit name and team.
local bot = GetBot()
local unitName = bot:GetUnitName()

-- Bail out early for non-hero / illusion / invalid bots.
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not string.find(unitName, "hero") or bot:IsIllusion() then
	return
end
if not bot.frameProcessTime then
	bot.frameProcessTime = 0.1
end
local team = GetTeam()

-- Constant "true" flag (always evaluates to true; used as a wildcard/always-on gate).
local val = 10 == 10

-- Shared framework modules.
local mod = require(GetScriptDirectory() .. "/FuncLib/func_utils")
local mod2 = require(GetScriptDirectory() .. "/FuncLib/systems/utils")
-- Hero-specific build/script table loaded from BotsLib/<hero> (without the npc_dota_ prefix).
local loadedScript = dofile(GetScriptDirectory() .. "/BotsLib/" .. string.gsub(unitName, "npc_dota_", ""))
local mod3 = require(GetScriptDirectory() .. "/FuncLib/systems/localization")
local mod4 = require(GetScriptDirectory() .. "/FuncLib/systems/custom_loader")
mod4.ThinkLess = mod4.Enable and mod4.ThinkLess or 1
-- Optional dispel system; tolerate load failure.
local ok, result = pcall(require, GetScriptDirectory() .. "/FuncLib/systems/dispel")
if not ok then
	result = nil
end

-- Game-mode constants (set once globally).
if GAMEMODE_TURBO == nil then
	GAMEMODE_TURBO = 23
end
if GAMEMODE_ARDM == nil then
	GAMEMODE_ARDM = 20
end

-- Abort if the hero script failed to load.
if loadedScript == nil then
	log("[ERROR] BotBuild is nil for %s - hero file failed to load. No items/abilities.", unitName)
	return
end

-- Build tables / skill list exported by the hero script.
local defaultAbility = loadedScript["bDeafaultAbility"]
local defaultItem = loadedScript["bDeafaultItem"]
local skillList = loadedScript["sSkillList"]

-- World-space coordinates of the Radiant and Dire ancient bases (used for retreat/fallback logic).
local radiantBase = Vector(-6619, -6336, 384)
local direBase = Vector(6928, 6372, 392)

-- Misc runtime flags/scratch values.
local flag = false
local val2 = nil

-- Kez ability-swap map: pairs of mutually swappable abilities (e.g. via Kazurai Katana / Shodo Sai).
local kezAbilitySwapMap = {
	["kez_echo_slash"] = "kez_falcon_rush",
	["kez_falcon_rush"] = "kez_echo_slash",
	["kez_grappling_claw"] = "kez_talon_toss",
	["kez_talon_toss"] = "kez_grappling_claw",
	["kez_kazurai_katana"] = "kez_shodo_sai",
	["kez_shodo_sai"] = "kez_kazurai_katana",
	["kez_raptor_dance"] = "kez_ravens_veil",
	["kez_ravens_veil"] = "kez_raptor_dance",
}
-- Reload the hero-specific script from BotsLib/ and refresh ability/item/skill tables.
local function reloadHeroScript(val3)
	local val4 = string.gsub(unitName, "npc_dota_", "")
	log("[Reload] %s for %s, loading BotsLib/%s", val3, unitName, val4)
	local ok2, result2 = pcall(dofile, GetScriptDirectory() .. "/BotsLib/" .. val4)
	if ok2 and result2 ~= nil then
		loadedScript = result2
		defaultAbility = loadedScript["bDeafaultAbility"]
		defaultItem = loadedScript["bDeafaultItem"]
		if result2["sSkillList"] ~= nil and #result2["sSkillList"] > 0 then
			local skillList2 = result2["sSkillList"]
			local val5 = bot:GetLevel()
			local val6 = val5 - bot:GetAbilityPoints()
			local tbl2 = {}
			for i2 = val6 + 1, #skillList2 do
				table.insert(tbl2, skillList2[i2])
			end
			if #tbl2 > 0 then
				skillList = tbl2
			else
				skillList = mod.Utils.CombineTablesUnique(mod.Skill.GetTalentList(bot), mod.Skill.GetAbilityList(bot))
			end
			log("[Reload] Skill list: %s entries remaining (spent %s points)", #skillList, val6)
		end
	else
		log("[Reload] dofile FAILED for %s: %s", val4, result2)
	end
end
-- Detect ARDM / hero-swap changes and reload the matching hero script when needed (returns true if reloaded).
local function reloadHeroScript2()
	local val7, val8, val9 = mod.IsStaleARDMHero(bot, unitName)
	if val7 then
		log("[ARDM] Stale ability script: this=%s, current=%s", unitName, val9)
		return true
	end
	if val9 ~= unitName then
		log("[ARDM] Hero swap detected: %s -> %s", unitName, val9)
		bot = val8
		unitName = val9
		flag = true
	elseif val8 ~= bot then
		bot = val8
	end
	if flag and bot:IsAlive() then
		flag = false
		local val10 = string.gsub(unitName, "npc_dota_", "")
		log("[ARDM] Loading BotsLib/%s.lua for %s", val10, unitName)
		local ok3, result3 = pcall(dofile, GetScriptDirectory() .. "/BotsLib/" .. val10)
		if not ok3 then
			log("[ARDM] dofile FAILED for %s: %s", val10, result3)
		end
		if ok3 and result3 ~= nil and result3["sSkillList"] ~= nil and #result3["sSkillList"] > 0 then
			loadedScript = result3
			defaultAbility = loadedScript["bDeafaultAbility"]
			defaultItem = loadedScript["bDeafaultItem"]
			skillList = loadedScript["sSkillList"]
			log("[ARDM] Loaded BotsLib for %s with %s skill entries, first: %s", unitName, #skillList, skillList[1])
		else
			local val11 = mod.Skill.GetAbilityList(bot)
			local val12 = mod.Skill.GetTalentList(bot)
			log("[ARDM] BotsLib load failed or empty for %s, abilities: %s, talents: %s", unitName, #val11, #val12)
			if #val11 > 0 then
				loadedScript = nil
				defaultAbility = false
				defaultItem = false
				skillList = mod.Utils.CombineTablesUnique(val12, val11)
				log("[ARDM] Using generic build for %s with %s entries", unitName, #skillList)
			else
				log("[ARDM] Abilities not ready for %s, retrying next frame", unitName)
				flag = true
			end
		end
	elseif flag and not bot:IsAlive() then
		log("[ARDM] Waiting for %s to respawn", unitName)
	end
	return false
end
-- Handle in-game hero swaps (e.g. ARDM / Morphling / Vanilla swap): re-point bot/unitName and rebuild skill list.
local function handleHeroSwap()
	if GetGameState() ~= GAME_STATE_PRE_GAME and GetGameState() ~= GAME_STATE_GAME_IN_PROGRESS then
		return
	end
	if mod.CanNotUseAbility(bot) then
		return
	end
	local val13 = mod.GetPosition(bot)
	if val2 == nil then
		val2 = val13
		if
			bot.isBear == nil
			and GetGameMode() ~= GAMEMODE_1V1MID
			and GetGameState() == GAME_STATE_PRE_GAME
			and bot.announcedRole ~= val13
		then
			pcall(function()
				bot:ActionImmediate_Chat(mod3.Get("say_play_pos") .. tostring(val13), false)
				bot.announcedRole = val13
			end)
		end
	elseif val13 ~= val2 then
		log("[PosSwap] %s position changed: pos%s -> pos%s", unitName, val2, val13)
		val2 = val13
		reloadHeroScript("Position swap to pos" .. val13)
		bot.needPurchaseRebuild = true
		if bot.isBear == nil and bot.announcedRole ~= val13 then
			pcall(function()
				bot:ActionImmediate_Chat(mod3.Get("say_play_pos") .. tostring(val13), false)
				bot.announcedRole = val13
			end)
		end
	end
	if bot:GetLevel() >= 30 and unitName == "npc_dota_hero_bloodseeker" then
		return
	end
	if DotaTime() < 15 then
		bot.theRole = mod.Role.GetCurrentSuitableRole(bot, unitName)
	end
	local val14 = bot:GetLocation()
	if
		bot:IsAlive()
		and DotaTime() > 90
		and bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO
		and not IsLocationPassable(val14)
	then
		if bot.stuckLoc == nil then
			bot.stuckLoc = val14
			bot.stuckTime = DotaTime()
		elseif bot.stuckLoc ~= val14 then
			bot.stuckLoc = val14
			bot.stuckTime = DotaTime()
		end
	else
		bot.stuckTime = nil
		bot.stuckLoc = nil
	end
	if bot.needRefreshAbilitiesFor737 ~= nil and loadedScript ~= nil then
		skillList = loadedScript["sSkillList"]
		if not bot.needRefreshAbilitiesFor737 then
			bot.needRefreshAbilitiesFor737 = nil
		end
	end
	local val15 = bot:GetLevel()
	if GetGameMode() == GAMEMODE_ARDM and bot:GetAbilityPoints() > 0 then
		if #skillList > 0 then
			log(
				"[ARDM] %s Lv%s has %s ability points, skill list has %s entries, next: %s",
				unitName,
				val15,
				bot:GetAbilityPoints(),
				#skillList,
				skillList[1]
			)
		else
			log("[ARDM] %s Lv%s has %s ability points, skill list has %s entries", unitName, val15, bot:GetAbilityPoints(), #skillList)
		end
	end
	if #skillList >= 1 and bot:GetAbilityPoints() > 0 then
		if mod.IsTryingtoUseAbility(bot) then
			return
		end
		local val16 = skillList[1]
		if val16 == nil then
			log("[WARN] Nil entry in sAbilityLevelUpList for %s, removing", unitName)
			table.remove(skillList, 1)
			return
		end
		local val17 = bot:GetAbilityByName(val16)
		if val17 == nil and GetGameMode() == GAMEMODE_ARDM then
			local val18 = mod.Skill.GetAbilityList(bot)
			local val19 = mod.Skill.GetTalentList(bot)
			if #val18 >= 3 then
				log(
					"[ARDM] Ability '%s' not found on %s, rebuilding skill list (abilities: %s, talents: %s)",
					val16,
					unitName,
					#val18,
					#val19
				)
				skillList = mod.Utils.CombineTablesUnique(val19, val18)
				return
			else
				log("[ARDM] Abilities not ready for %s (%s), waiting", unitName, #val18)
				return
			end
		end
		if val17 ~= nil and val17:IsHidden() then
			local val20 = kezAbilitySwapMap[val16]
			if val20 then
				local val21 = bot:GetAbilityByName(val20)
				if val21 ~= nil and not val21:IsHidden() then
					val17 = val21
					val16 = val20
				end
			end
		end
		if val16 == "phoenix_fire_spirits" then
			local val22 = bot:GetAbilityByName("phoenix_launch_fire_spirit")
			if val22 ~= nil and not val22:IsHidden() then
				return
			end
		end
		if val16 == "alchemist_unstable_concoction" then
			local val23 = bot:GetAbilityByName("alchemist_unstable_concoction_throw")
			if val23 ~= nil and not val23:IsHidden() then
				return
			end
		end
		if val17 == nil then
			log("[ARDM] Ability %s not found on %s, skipping", val16, unitName)
			table.remove(skillList, 1)
			return
		end
		if
			not val17:IsHidden()
			and val15 >= val17:GetHeroLevelRequiredToUpgrade()
			and val17:CanAbilityBeUpgraded()
			and val17:GetLevel() < val17:GetMaxLevel()
		then
			bot:ActionImmediate_LevelAbility(val17:GetName())
			table.remove(skillList, 1)
		elseif val16 == "generic_hidden" then
			local val24 = skillList[2]
			log("[WARN] Level up ability %s for %s does not make sense. try to upgrade the next ability: %s", val16, unitName, val24)
			table.remove(skillList, 1)
			if val24 then
				bot:ActionImmediate_LevelAbility(val24)
			end
		elseif not val17:IsHidden() and val15 >= val17:GetHeroLevelRequiredToUpgrade() then
			log(
				"[WARN] Level up ability %s for %s may fail because it was called on ability that's not available or can't get upgraded anymore.",
				val16,
				unitName
			)
			bot:ActionImmediate_LevelAbility(val16)
			table.remove(skillList, 1)
		else
			log("[WARN] Skipped to level up ability %s for %s for this time because it may fail.", val16, unitName)
			if val15 > 25 then
				log("[WARN] Ignore ability %s for %s because it may always fail.", val16, unitName)
				table.remove(skillList, 1)
			end
		end
	end
	if val15 > 25 and val15 < 30 and bot:GetAbilityPoints() >= 1 and #skillList <= 3 then
		skillList = mod.Utils.CombineTablesUnique(mod.Skill.GetTalentList(bot), mod.Skill.GetAbilityList(bot))
	end
	if GetGameMode() == GAMEMODE_ARDM and #skillList == 0 and bot:GetAbilityPoints() > 0 then
		log("[ARDM] Skill list exhausted for %s at Lv%s with %s points, rebuilding", unitName, val15, bot:GetAbilityPoints())
		skillList = mod.Utils.CombineTablesUnique(mod.Skill.GetTalentList(bot), mod.Skill.GetAbilityList(bot))
	end
end
function abilityItemUsage.GetLaneByPosition(val25)
	if IsLanMode and IsLanMode() then
		local val26 = val25:GetAssignedLane()
		if val26 == LANE_TOP or val26 == LANE_MID or val26 == LANE_BOT then
			return val26
		end
	end
	local val27 = mod.GetPosition(val25)
	if GetTeam() == TEAM_RADIANT then
		if val27 == 1 then
			return LANE_BOT
		elseif val27 == 2 then
			return LANE_MID
		elseif val27 == 3 or val27 == 4 then
			return LANE_TOP
		elseif val27 == 5 then
			return LANE_BOT
		end
	else
		if val27 == 1 then
			return LANE_TOP
		elseif val27 == 2 then
			return LANE_MID
		elseif val27 == 3 or val27 == 4 then
			return LANE_BOT
		elseif val27 == 5 then
			return LANE_TOP
		end
	end
	return val25:GetAssignedLane() or LANE_MID
end
function abilityItemUsage.GetNumEnemyNearby(val28)
	local value = 0
	for loopVar, loopVar2 in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(loopVar2) then
			local val29 = GetHeroLastSeenInfo(loopVar2)
			if val29 ~= nil then
				local val30 = val29[1]
				if val30 ~= nil and GetUnitToLocationDistance(val28, val30.location) <= 3000 and val30.time_since_seen < 1.0 then
					value = value + 1
				end
			end
		end
	end
	return value
end
local a0 = 0
function abilityItemUsage.GetRemainingRespawnTime()
	if a0 == 0 then
		return 0
	else
		return bot:GetRespawnTime() - (DotaTime() - a0)
	end
end
local a1 = RandomInt(14, 20)
local a2 = RandomInt(19, 56) / 10
local a3 = -999
local a4 = 9999
local a5 = 999
local a6 = 0
local a7 = 0
local a8 = 0
local a9 = RandomInt(5, 9)
local aa = false
local ab = nil
local ac = nil
local ad = false
function abilityItemUsage.SetTalkMessage()
	local ae = bot:GetPlayerID()
	local af = bot:GetGold()
	local ag = GetHeroKills(ae)
	local ah = GetHeroDeaths(ae)
	local ai = GetGameMode() == GAMEMODE_TURBO and 2.0 or 1.0
	if ae == mod.Role.GetReplyMemberID() and a8 <= a9 then
		if not aa and GetGameState() == GAME_STATE_GAME_IN_PROGRESS then
			aa = true
			InstallChatCallback(function(aj)
				abilityItemUsage.SetReplyHumanTime(aj)
			end)
		end
		if ac ~= nil and ab ~= nil and DotaTime() > ab + a2 then
			local ak = mod.Chat.GetReplyString(ac, ad)
			if ak ~= nil then
				if a8 == a9 then
					ak = mod.Chat.GetStopReplyString()
				end
				bot:ActionImmediate_Chat(ak, ad)
				a8 = a8 + 1
				a2 = RandomInt(6, 30) / 10
				if a2 > 2.0 then
					a2 = RandomInt(6, 30) / 10
				end
			end
			ac = nil
			ab = nil
		end
	end
	if mod.Customize.Allow_Trash_Talk then
		if
			DotaTime() < 600
			and bot:IsAlive()
			and ag > a5
			and mod.GetNumOfTeamTotalKills(false) == 1
			and mod.GetNumOfTeamTotalKills(true) == 0
			and RandomInt(1, 9) > 4
		then
			local al = mod3.Get("got_first_blood")[RandomInt(1, #mod3.Get("got_first_blood"))]
			bot:ActionImmediate_Chat(al, true)
		end
		if bot:IsAlive() and af > a4 + 300 * ai and ag > a5 then
			local al = "?"
			if mod.Customize.Trash_Talk_Level and mod.Customize.Trash_Talk_Level >= 2 then
				if RandomInt(1, 9) > 7 then
					al = mod3.Get("got_a_kill")[RandomInt(1, #mod3.Get("got_a_kill"))]
				end
				if af > a4 + 800 * ai and RandomInt(1, 9) > 4 then
					al = mod3.Get("got_big_kill")[RandomInt(1, #mod3.Get("got_big_kill"))]
				end
				if af > a4 + 1000 * ai and RandomInt(1, 9) > 3 then
					al = mod3.Get("got_big_kill_2")[RandomInt(1, #mod3.Get("got_big_kill_2"))]
				end
				if af > a4 + 1500 * ai then
					al = mod3.Get("got_big_kill_3")[RandomInt(1, #mod3.Get("got_big_kill_3"))]
				end
			end
			if RandomInt(1, 9) > 4 then
				bot:ActionImmediate_Chat(al, true)
			end
		end
		if not bot:IsAlive() then
			if a7 >= 8 and a3 == -999 then
				a3 = DotaTime()
				a7 = 0
			end
			if a3 ~= -999 and a3 < DotaTime() - a2 then
				bot:ActionImmediate_Chat(mod3.Get("kill_streak_ended")[RandomInt(1, #mod3.Get("kill_streak_ended"))], true)
				a3 = -999
				a2 = RandomInt(36, 49) / 10
			end
		end
		if ag == 0 and ah >= a1 and mod.Role.NotSayJiDi() then
			bot:ActionImmediate_Chat(mod3.Get("say_end")[RandomInt(1, #mod3.Get("say_end"))], true)
			mod.Role["sayJiDi"] = true
		end
	end
	if a6 == ah then
		if ag >= a5 + 1 then
			a7 = a7 + 1
		end
	else
		a7 = 0
	end
	a5 = GetHeroKills(ae)
	a6 = GetHeroDeaths(ae)
	a4 = bot:GetGold()
end
function abilityItemUsage.SetReplyHumanTime(aj)
	local am = aj.string
	local an = aj.player_id
	if string.find(am, "!sp") or string.find(am, "!speak") then
		local ao, ap = mod.Utils.TrimString(am):match("^(%S+)%s+(.*)$")
		log("Set to speak: %s", ap)
		mod.Customize.Localization = ap
		return
	end
	if am ~= "-都来守家" or mod.Role.IsAllyMemberID(an) then
		mod.Role.SetLastChatString(am)
	end
	if not IsPlayerBot(an) and (aj.team_only or mod.Role.IsEnemyMemberID(an)) then
		ac = am
		ab = DotaTime()
		ad = not aj.team_only
	end
end
local function aq()
	if mod.IsMeepoClone(bot) then
		return
	end
	abilityItemUsage.SetTalkMessage()
	if bot:GetLevel() <= 15 or bot:HasModifier("modifier_arc_warden_tempest_double") or not mod.Role.ShouldBuyBack() then
		return
	end
	if bot:IsAlive() and a0 ~= 0 then
		a0 = 0
	end
	if not bot:IsAlive() then
		if a0 == 0 then
			a0 = DotaTime()
		end
	end
	if bot:IsAlive() then
		return
	end
	if not bot:HasBuyback() then
		return
	end
	local ar = GetAncient(GetTeam())
	local as = bot:GetRespawnTime()
	local at = abilityItemUsage.GetRemainingRespawnTime()
	if ar ~= nil and ar:GetHealth() < 0.8 then
		local au = mod.GetEnemiesAroundLoc(ar:GetLocation(), 1500)
		local av = mod.GetAlliesNearLoc(ar:GetLocation(), 1500)
		if au > 1 and av == 0 and at > 20 then
			mod.Role["lastbbtime"] = DotaTime()
			bot:ActionImmediate_Buyback()
			return
		end
	end
	if as < 45 then
		return
	end
	if bot:GetLevel() > 24 and at > 80 then
		local aw = mod.GetTeamFightLocation(bot)
		if aw ~= nil then
			mod.Role["lastbbtime"] = DotaTime()
			bot:ActionImmediate_Buyback()
			return
		end
	end
	if at < 40 then
		return
	end
	if ar ~= nil then
		local ax = abilityItemUsage.GetNumEnemyNearby(ar)
		local ay = mod.GetNumOfAliveHeroes(false)
		if ax > 0 and ax >= ay then
			mod.Role["lastbbtime"] = DotaTime()
			bot:ActionImmediate_Buyback()
			return
		end
	end
end
local az = -90
local aA = -1
bot.SShopUser = false
local aB = -90
local aC = -90
local function aD()
	if DotaTime() < -56 or bot:HasModifier("modifier_arc_warden_tempest_double") or aB + 5.0 > DotaTime() then
		return
	end
	if bot.theCourier == nil then
		bot.theCourier = abilityItemUsage.GetBotCourier(bot)
		return
	end
	local aE = 10 == 10
	local aF = bot.theCourier
	aA = GetCourierState(aF)
	local aG = aF:GetHealth() / aF:GetMaxHealth()
	local aH = DotaTime()
	local aI = bot:IsAlive()
	local aJ = bot:GetLevel()
	local aK = 2.3
	local aL = 5.0
	if aA == COURIER_STATE_DEAD then
		return
	end
	if abilityItemUsage.IsCourierTargetedByUnit(aF) then
		if aH > aB + aL then
			aB = aH
			mod.SetReportMotive(aE, "信使可能会被攻击")
			bot:ActionImmediate_Courier(aF, COURIER_ACTION_RETURN_STASH_ITEMS)
			local aM = aF:GetAbilityByName("courier_burst")
			if aM and aM:IsFullyCastable() then
				bot:ActionImmediate_Courier(aF, COURIER_ACTION_BURST)
			end
			return
		end
	end
	if bot.SShopUser and (not aI or bot:GetActiveMode() == BOT_MODE_SECRET_SHOP or not bot.SecretShop) then
		bot.SShopUser = false
		mod.SetReportMotive(aE, "让信使返回基地避免被卡住")
		bot:ActionImmediate_Courier(aF, COURIER_ACTION_RETURN_STASH_ITEMS)
		return
	end
	if
		(aA == COURIER_STATE_RETURNING_TO_BASE or aA == COURIER_STATE_AT_BASE or aA == COURIER_STATE_IDLE)
		and aH > aB + aL
	then
		if aA == COURIER_STATE_AT_BASE and aG < 0.8 then
			return
		end
		if aA == COURIER_STATE_IDLE and aF:DistanceFromFountain() > 800 then
			mod.SetReportMotive(aE, "让空闲的信使返回")
			bot:ActionImmediate_Courier(aF, COURIER_ACTION_RETURN_STASH_ITEMS)
			return
		end
		if
			aI
			and (not abilityItemUsage.IsInvFull(bot) or aH <= 5 * 60 or bot.currBuyingBasicItemList ~= nil and #bot.currBuyingBasicItemList == 0 and bot.currBuyingItemInPurchaseList ~= "item_travel_boots")
			and (aA == COURIER_STATE_AT_BASE or aA == COURIER_STATE_IDLE and aF:DistanceFromFountain() < 800)
		then
			local aN = abilityItemUsage.GetNumStashItem(bot)
			if aN > 0 then
				if
					bot.currBuyingBasicItemList ~= nil and #bot.currBuyingBasicItemList == 0
					or bot.currBuyingBasicItem ~= nil
						and (IsItemPurchasedFromSecretShop(bot.currBuyingBasicItem) or abilityItemUsage.GetNumStashItem(bot) == 6 or bot:GetGold() + 80 < GetItemCost(
							bot.currBuyingBasicItem
						))
				then
					mod.SetReportMotive(aE, "信使取出物品并开始运输")
					bot:ActionImmediate_Courier(aF, COURIER_ACTION_TAKE_STASH_ITEMS)
					az = aH
					if aH > aC + aL then
						aC = aH
						local aM = aF:GetAbilityByName("courier_burst")
						if aM and aM:IsFullyCastable() then
							mod.SetReportMotive(aE, "信使加速配送")
							bot:ActionImmediate_Courier(aF, COURIER_ACTION_BURST)
						end
					end
				end
			end
		end
		if
			aI
			and bot.SecretShop
			and aF:DistanceFromFountain() < 7000
			and mod.Item.GetEmptyInventoryAmount(aF) >= 2
			and not abilityItemUsage.IsEnemyHeroAroundSecretShop()
			and aH > az + aK
		then
			mod.SetReportMotive(aE, "信使前往神秘商店购物")
			bot:ActionImmediate_Courier(aF, COURIER_ACTION_SECRET_SHOP)
			bot.SShopUser = true
			az = aH
			return
		end
		if
			aI
			and bot:GetCourierValue() > 0
			and bot:GetStashValue() < 100
			and (not abilityItemUsage.IsInvFull(bot) or abilityItemUsage.GetNumStashItem(bot) == 0 and bot.currBuyingBasicItemList ~= nil and #bot.currBuyingBasicItemList == 0)
			and (aF:DistanceFromFountain() < 4000 + aJ * 200 or GetUnitToUnitDistance(bot, aF) < 1800)
			and aH > az + aK
		then
			mod.SetReportMotive(aE, "信使运输背包中的东西")
			bot:ActionImmediate_Courier(aF, COURIER_ACTION_TRANSFER_ITEMS)
			az = aH
			return
		end
	end
end
function abilityItemUsage.GetBotCourier(val31)
	local aO = val31:GetPlayerID()
	for aP = 0, 4 do
		local aQ = GetCourier(aP)
		if aQ:GetPlayerID() == aO then
			return aQ
		end
	end
end
function abilityItemUsage.GetNumStashItem(aR)
	local aS = 0
	for i3 = 9, 14 do
		if aR:GetItemInSlot(i3) ~= nil then
			aS = aS + 1
		end
	end
	return aS
end
function abilityItemUsage.IsThereRecipeInStash(aR)
	local aS = 0
	for i4 = 9, 14 do
		local aT = aR:GetItemInSlot(i4)
		if aT ~= nil then
			if string.find(aT:GetName(), "item_recipe_") then
				aS = aS + 1
			end
		end
	end
	return aS > 0
end
function abilityItemUsage.IsCourierTargetedByUnit(aQ)
	if GetGameMode() == GAMEMODE_TURBO then
		return false
	end
	local aJ = bot:GetLevel()
	if mod.GetHP(aQ) < 0.9 then
		return true
	end
	if aQ:DistanceFromFountain() < 900 then
		return false
	end
	for i5 = 0, 10 do
		local aU = GetTower(GetOpposingTeam(), i5)
		if aU ~= nil and aU:CanBeSeen() then
			local aV = aU:GetAttackTarget()
			if aV == aQ then
				return true
			end
			if aV == nil and GetUnitToUnitDistance(aQ, aU) < 999 then
				return true
			end
		end
	end
	for loopVar3, loopVar4 in pairs(GetTeamPlayers(GetOpposingTeam())) do
		if IsHeroAlive(loopVar4) then
			local val32 = GetHeroLastSeenInfo(loopVar4)
			if val32 ~= nil then
				local val33 = val32[1]
				if val33 ~= nil and GetUnitToLocationDistance(aQ, val33.location) <= 800 and val33.time_since_seen < 1.8 then
					return true
				end
			end
		end
	end
	local aW = GetUnitList(UNIT_LIST_ENEMY_HEROES)
	for aX, aY in pairs(aW) do
		if GetUnitToUnitDistance(aY, aQ) <= 700 + aJ * 15 then
			local aZ = mod.GetAlliesNearLoc(aY:GetLocation(), 600)
			if #aZ == 0 or aY:GetAttackTarget() == aQ then
				return true
			end
		end
		if aY:GetUnitName() == "npc_dota_hero_sniper" and GetUnitToUnitDistance(aY, aQ) <= 1100 + aJ * 30 then
			return true
		end
		if GetUnitToUnitDistance(aY, aQ) <= aY:GetAttackRange() + 88 then
			return true
		end
	end
	local a_ = mod.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE)
	for aX, aY in pairs(a_) do
		if aY ~= nil and mod.IsValidHero(aY) and GetUnitToUnitDistance(aY, aQ) <= 700 + aJ * 15 then
			local aZ = mod.GetAlliesNearLoc(aY:GetLocation(), 800)
			if #aZ == 0 or aY:GetAttackTarget() == aQ then
				return true
			end
		end
		if aY ~= nil and mod.IsValidHero(aY) and GetUnitToUnitDistance(aY, aQ) <= aY:GetAttackRange() + 100 then
			return true
		end
	end
	local b0 = GetUnitList(UNIT_LIST_ENEMY_CREEPS)
	local aZ = mod.GetAlliesNearLoc(aQ:GetLocation(), 1500)
	local b1 = #aZ
	for aX, b2 in pairs(b0) do
		if
			GetUnitToUnitDistance(aQ, b2) <= 800
			and (b2:GetAttackTarget() == aQ or aJ > 10)
			and (b1 == 0 or b2:GetAttackTarget() == aQ)
		then
			return true
		end
	end
	return false
end
function abilityItemUsage.IsInvFull(val34)
	for i6 = 0, 8 do
		if val34:GetItemInSlot(i6) == nil then
			return false
		end
	end
	return true
end
function abilityItemUsage.IsEnemyHeroAroundSecretShop()
	local b3 = GetShopLocation(team, SHOP_SECRET)
	local b4 = GetShopLocation(team, SHOP_SECRET2)
	local b5 = team == TEAM_DIRE and b4 or b3
	local b6 = (b5 + GetAncient(team):GetLocation()) * 0.5
	if mod.IsEnemyHeroAroundLocation(b6, 2000) then
		return true
	end
	return false
end
local b7 = {}
local b8 = 0
local b9 = 0
local ba = false
local bb = -90
local bc = {}
local bd = {}
local be = nil
local bf = -1
local function bg()
	abilityItemUsage.SetStashItemTimeUpdate()
	if
		not bot:IsAlive()
		or bot:IsMuted()
		or bot:IsHexed()
		or bot:IsStunned()
		or bot:IsChanneling()
		or bot:IsInvulnerable()
		or bot:IsUsingAbility()
		or bot:IsCastingAbility()
		or bot:NumQueuedActions() > 0
		or bot:HasModifier("modifier_teleporting")
		or bot:HasModifier("modifier_doom_bringer_doom_aura_enemy")
		or bot:HasModifier("modifier_phantom_lancer_phantom_edge_boost")
		or bot:HasModifier("modifier_life_stealer_infest")
		or bot:HasModifier("modifier_nyx_assassin_vendetta") and mod.IsRealInvisible(bot)
		or abilityItemUsage.WillBreakInvisible(bot)
	then
		return BOT_ACTION_DESIRE_NONE
	end
	bc = mod.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE)
	bd = bot:GetNearbyTowers(888, true)
	be = mod.GetProperTarget(bot)
	bf = bot:GetActiveMode()
	if bf ~= BOT_MODE_ATTACK and bf ~= BOT_MODE_RETREAT then
		local bh = false
		local bi = bot:GetAttackTarget()
		if bi ~= nil and bi:IsHero() then
			bh = true
		elseif #bc > 0 and (bot:WasRecentlyDamagedByAnyHero(2.0) or mod.IsAttacking(bot)) then
			bh = true
		end
		if bh then
			bf = BOT_MODE_ATTACK
		end
	end
	local bj = mod.IsItemAvailable("item_aether_lens")
	if bj ~= nil then
		b8 = 250
	else
		b8 = 0
	end
	local bk = { 0, 1, 2, 3, 4, 5, 15, 16 }
	for aX, bl in pairs(bk) do
		local bm = bot:GetItemInSlot(bl)
		if mod.CanCastAbility(bm) then
			local bn = bm:GetName()
			if abilityItemUsage.ConsiderItemDesire[bn] ~= nil and not abilityItemUsage.IsItemInStash(bn) then
				local bo, bp, bq = abilityItemUsage.ConsiderItemDesire[bn](bm)
				if bo > 0 then
					abilityItemUsage.SetUseItem(bm, bp, bq)
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
function abilityItemUsage.SetUseItem(bm, bp, bq)
	if bq == "none" then
		bot:Action_UseAbility(bm)
		return
	elseif bq == "unit" and type(bp) == "table" then
		bot:Action_UseAbilityOnEntity(bm, bp)
		if string.find(bm:GetName(), "tango") then
			bot._lastTangoUseTime = DotaTime()
		end
		return
	elseif bq == "ground" or bp and type(bp) ~= "number" and type(bp) ~= "table" and bp.x ~= nil then
		bot:Action_UseAbilityOnLocation(bm, bp)
		return
	elseif bq == "tree" then
		bot:Action_UseAbilityOnTree(bm, bp)
		bot._lastTangoUseTime = DotaTime()
		return
	elseif bq == "twice" then
		bot:Action_UseAbility(bm)
		bot:ActionQueue_UseAbility(bm)
		return
	end
end
function abilityItemUsage.IsWithoutSpellShield(br)
	return not br:HasModifier("modifier_item_sphere_target")
		and not br:HasModifier("modifier_antimage_spell_shield")
		and not br:HasModifier("modifier_item_lotus_orb_active")
end
local bs = -90
function abilityItemUsage.SetStashItemTimeUpdate()
	local aH = DotaTime()
	for i7 = 6, 8 do
		local bm = bot:GetItemInSlot(i7)
		if bm ~= nil then
			b7[bm:GetName()] = aH
		end
	end
	if aH > bs + 7.0 then
		bs = aH
		for bt, bu in pairs(b7) do
			if bu ~= nil and bu < aH - 7.0 then
				b7[bt] = nil
			end
		end
	end
end
function abilityItemUsage.IsItemInStash(bn)
	if b7[bn] ~= nil and DotaTime() < b7[bn] + 6.05 then
		return true
	end
	return false
end
function abilityItemUsage.WillBreakInvisible(val35)
	if not val35:IsInvisible() then
		return false
	end
	local val36 = val36
	if val36 == "npc_dota_hero_riki" or val36 == "npc_dota_hero_bounty_hunter" or val36 == "npc_dota_hero_slark" then
		return false
	end
	if val35:HasModifier("modifier_phantom_assassin_blur_active") then
		return false
	end
	if val35:HasModifier("modifier_item_glimmer_cape_fade") then
		return false
	end
	if val35:HasModifier("modifier_item_shadow_amulet_fade") then
		return true
	end
	if
		val35:HasModifier("modifier_item_invisibility_edge_windwalk") or val35:HasModifier("modifier_item_silver_edge_windwalk")
	then
		return true
	end
	if val35:HasModifier("modifier_smoke_of_deceit") then
		return true
	end
	return false
end
-- Dispatch table mapping each neutral/item name to its "should I use it?" evaluator.
-- Each entry is function(bot) -> (desireNumber, target, castType); called every frame by ItemUsageThink.
abilityItemUsage.ConsiderItemDesire = {}
abilityItemUsage.ConsiderItemDesire["item_abyssal_blade"] = function(bm)
	local bv = 620 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	for aX, br in pairs(bx) do
		if mod.IsValid(br) and mod.CanCastOnNonMagicImmune(br) and abilityItemUsage.IsWithoutSpellShield(br) then
			if br:IsChanneling() or br:IsCastingAbility() then
				hEffectTarget = br
				bw = "打断:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if bf == BOT_MODE_RETREAT and not mod.IsDisabled(br) then
				hEffectTarget = br
				bw = "撤退:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.IsInRange(bot, be, bv + 50)
			and mod.CanCastOnNonMagicImmune(be)
			and abilityItemUsage.IsWithoutSpellShield(be)
			and not mod.IsDisabled(be)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_ancient_janggo"] = function(bm)
	if bm:GetCurrentCharges() <= 0 and bm:GetName() == "item_ancient_janggo" then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 680
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bot:HasModifier("modifier_nyx_assassin_vendetta") then
		return BOT_ACTION_DESIRE_NONE
	end
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidHero(be) and mod.CanCastOnMagicImmune(be) and mod.IsInRange(bot, be, bv) then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_arcane_boots"] = function(bm)
	if bot:DistanceFromFountain() < 800 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 1200
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local by = mod.GetAllyList(bot, bv)
	if #by >= 2 and bot:GetHealth() <= 120 and bot:WasRecentlyDamagedByAnyHero(3.0) then
		bw = "死前为队友用"
		return BOT_ACTION_DESIRE_HIGH, by[2], bq, bw
	end
	local bz = 0
	for aX, bA in pairs(by) do
		if bA ~= nil and bA:IsAlive() and bA:GetMaxMana() - bA:GetMana() > 180 then
			bz = bz + 1
		end
		if bz >= 2 then
			bw = "团队回蓝"
			return BOT_ACTION_DESIRE_HIGH, by[2], bq, bw
		end
	end
	if bot:GetMana() / bot:GetMaxMana() < 0.65 then
		bw = "自己补蓝"
		return BOT_ACTION_DESIRE_HIGH, bot, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_armlet"] = function(bm)
	local bB = bm:GetToggleState()
	if
		mod.IsValid(be)
		and mod.CanBeAttacked(be)
		and mod.IsInRange(bot, be, bot:GetAttackRange() + 300)
		and (not be:IsBuilding() or not string.find(be:GetUnitName(), "OutpostName"))
		and not bot:IsDisarmed()
	then
		if not bB then
			return BOT_ACTION_DESIRE_HIGH, nil, "none"
		else
			return BOT_ACTION_DESIRE_NONE
		end
	end
	if mod.IsRetreating(bot) and not mod.IsRealInvisible(bot) then
		if mod.GetHP(bot) < 0.2 then
			if
				bot:WasRecentlyDamagedByAnyHero(2.0)
				or mod.IsAttackProjectileIncoming(bot, 1200)
				or mod.IsStunProjectileIncoming(bot, 550)
			then
				if not bB then
					return BOT_ACTION_DESIRE_HIGH, nil, "none"
				else
					return BOT_ACTION_DESIRE_NONE
				end
			end
		end
	end
	if
		mod.GetAttackProjectileDamageByRange(bot, 600) > bot:GetHealth() * 2
		or mod.IsStunProjectileIncoming(bot, 600) and mod.GetHP(bot) < 0.25
	then
		if not bB then
			return BOT_ACTION_DESIRE_HIGH, nil, "none"
		else
			return BOT_ACTION_DESIRE_NONE
		end
	end
	if bB then
		return BOT_ACTION_DESIRE_HIGH, nil, "none"
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_bfury"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_quelling_blade"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_black_king_bar"] = function(bm)
	if bot:HasModifier("modifier_dazzle_nothl_projection_soul_debuff") then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 1300
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		#bx > 0
		and not bot:IsMagicImmune()
		and not bot:IsInvulnerable()
		and not bot:HasModifier("modifier_item_lotus_orb_active")
		and not bot:HasModifier("modifier_antimage_spell_shield")
		and (mod.IsGoingOnSomeone(bot) or mod.IsRetreating(bot))
	then
		local bC = mod.GetEnemyCount(bot, 600)
		if bot:IsRooted() then
			bw = "解缠绕"
			return BOT_ACTION_DESIRE_HIGH, bot, bq, bw
		end
		if
			bot:IsSilenced()
			and bot:GetMana() > 100
			and not bot:HasModifier("modifier_item_mask_of_madness_berserk")
			and bC >= 2
		then
			bw = "解沉默"
			return BOT_ACTION_DESIRE_HIGH, bot, bq, bw
		end
		if mod.IsNotAttackProjectileIncoming(bot, 350) and bC >= 1 then
			bw = "防御弹道"
			return BOT_ACTION_DESIRE_HIGH, bot, bq, bw
		end
		if mod.IsWillBeCastUnitTargetSpell(bot, bv) and bC >= 1 then
			bw = "防御指向技能"
			return BOT_ACTION_DESIRE_HIGH, bot, bq, bw
		end
		if mod.IsWillBeCastPointSpell(bot, bv) and bC >= 1 then
			bw = "防御地点技能"
			return BOT_ACTION_DESIRE_HIGH, bot, bq, bw
		end
		if mod.GetEnemyCount(bot, 800) >= 3 then
			bw = "先开BKB切入"
			return BOT_ACTION_DESIRE_HIGH, bot, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_blade_mail"] = function(bm)
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsNotAttackProjectileIncoming(bot, 366) and #bx >= 1 then
		hEffectTarget = bot
		bw = "反弹弹道"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	for aX, br in pairs(bc) do
		if
			mod.IsValidHero(br)
			and mod.CanCastOnNonMagicImmune(br)
			and br:GetAttackTarget() == bot
			and (bot:WasRecentlyDamagedByHero(br, 5.0) or mod.IsAttackProjectileIncoming(bot, 1000))
		then
			hEffectTarget = br
			bw = "反弹敌人伤害:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_blink"] = function(bm)
	local bv = 1200
	if bm:GetName() == "item_arcane_blink" then
		bv = 1400
	end
	bv = bv + b8
	if mod.HasItemInInventory("item_magnifying_monocle") then
		bv = bv + 100
	end
	if mod.HasItemInInventory("item_enhancement_keen_eyed") then
		if DotaTime() >= (mod.IsModeTurbo() and 7.5 * 60 or 15 * 60) then
			bv = bv + 125
		elseif DotaTime() >= (mod.IsModeTurbo() and 12.5 * 60 or 25 * 60) then
			bv = bv + 135
		end
	end
	if mod.HasItemInInventory("item_enhancement_mystical") then
		if DotaTime() >= (mod.IsModeTurbo() and 17.5 * 60 or 35 * 60) then
			bv = bv + 100
		end
	end
	if mod.HasItemInInventory("item_enhancement_boundless") then
		if DotaTime() >= (mod.IsModeTurbo() and 30 * 60 or 60 * 60) then
			bv = bv + 350
		end
	end
	local unitName2 = bot:GetUnitName()
	if bot:IsRooted() or bot:HasModifier("modifier_nyx_assassin_vendetta") then
		return BOT_ACTION_DESIRE_NONE
	end
	if mod.IsStuck(bot) then
		local bD = mod.GetLocationTowardDistanceLocation(bot, GetAncient(GetTeam()):GetLocation(), bv)
		return BOT_ACTION_DESIRE_HIGH, bD, "ground", nil
	end
	local bE = bot:GetNearbyHeroes(800, false, BOT_MODE_ATTACK)
	if mod.IsRetreating(bot) and not mod.IsRealInvisible(bot) and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE then
		local bF = mod.GetLocationTowardDistanceLocation(bot, GetAncient(GetTeam()):GetLocation(), bv)
		local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 1200)
		if
			bot:DistanceFromFountain() > 900
			and IsLocationPassable(bF)
			and (#bE <= 1 or bot:GetActiveModeDesire() > BOT_MODE_DESIRE_VERYHIGH * 0.9)
			and nInRangeEnemy ~= nil
			and #nInRangeEnemy >= 1
		then
			return BOT_ACTION_DESIRE_HIGH, bF, "ground", nil
		end
	end
	bE = bot:GetNearbyHeroes(1600, false, BOT_MODE_ATTACK)
	if
		#bE <= 1
		and (be == nil or not be:IsHero())
		and mod.IsFarming(bot)
		and not bot:WasRecentlyDamagedByAnyHero(3.1)
		and not mod.IsPushing(bot)
		and not mod.IsDefending(bot)
	then
		local bG = bot:FindAoELocation(true, false, bot:GetLocation(), bv, 500, 0, 0)
		local bH = bot:GetNearbyLaneCreeps(1600, true)
		local nInRangeEnemy = mod.GetEnemiesNearLoc(bG.targetloc, 1600)
		if bH ~= nil and #bH >= 4 and nInRangeEnemy ~= nil and #nInRangeEnemy == 0 and bG.count >= 4 then
			local bI = mod.GetCenterOfUnits(bH)
			local bJ = GetUnitToLocationDistance(bot, bI)
			local bF = mod.GetLocationTowardDistanceLocation(bot, bI, bJ + 550)
			local bK = mod.GetLocationTowardDistanceLocation(bot, bI, bJ - 300)
			if bJ > bv then
				bK = mod.GetLocationTowardDistanceLocation(bot, bI, bv)
			end
			if
				IsLocationPassable(bK)
				and GetUnitToLocationDistance(bot, bK) > 600
				and IsLocationVisible(bF)
				and not mod.IsLocHaveTower(700, true, bK)
			then
				return BOT_ACTION_DESIRE_HIGH, bK, "ground", nil
			end
		end
	end
	if
		mod.IsProjectileIncoming(bot, 1200)
		and (be == nil or not be:IsHero() or not mod.IsInRange(bot, be, bot:GetAttackRange() + 100))
	then
		local bD = mod.GetLocationTowardDistanceLocation(bot, GetAncient(GetTeam()):GetLocation(), 1199)
		return BOT_ACTION_DESIRE_HIGH, bD, "ground", nil
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			bot.shouldBlink ~= nil
			and bot.shouldBlink
			and (
				unitName2 == "npc_dota_hero_batrider"
				or unitName2 == "npc_dota_hero_beastmaster"
				or unitName2 == "npc_dota_hero_dark_seer"
				or unitName2 == "npc_dota_hero_earthshaker"
				or unitName2 == "npc_dota_hero_magnataur"
				or unitName2 == "npc_dota_hero_rubick"
				or unitName2 == "npc_dota_hero_tiny"
				or unitName2 == "npc_dota_hero_treant"
			)
		then
			return BOT_ACTION_DESIRE_NONE
		end
		if unitName2 == "npc_dota_hero_nevermore" then
			local bL = bot:GetAbilityByName("nevermore_requiem")
			if mod.CanCastAbility(bL) then
				return BOT_ACTION_DESIRE_NONE
			end
		end
		if
			mod.IsValidTarget(be)
			and mod.IsInRange(bot, be, bv)
			and mod.CanBeAttacked(be)
			and not mod.IsInRange(bot, be, 500)
			and not be:HasModifier("modifier_faceless_void_chronosphere_freeze")
			and not be:HasModifier("modifier_enigma_black_hole_pull")
		then
			local bE = mod.GetAlliesNearLoc(be:GetLocation(), 1200)
			local nInRangeEnemy = mod.GetEnemiesNearLoc(be:GetLocation(), 1200)
			local bM = mod.WeAreStronger(bot, 1200)
			local bN = 0
			for aX, loopVar5 in pairs(GetTeamPlayers(GetOpposingTeam())) do
				if IsHeroAlive(loopVar5) then
					local val37 = GetHeroLastSeenInfo(loopVar5)
					if val37 ~= nil then
						local val38 = val37[1]
						if
							val38 ~= nil
							and val38.time_since_seen < 3.0
							and GetUnitToLocationDistance(be, val38.location) <= 1200
						then
							bN = bN + 1
						end
					end
				end
			end
			if #bE >= bN and bM then
				local bO = Min(bv, GetUnitToUnitDistance(bot, be))
				local bF = mod.GetUnitTowardDistanceLocation(bot, be, bO) + RandomVector(150)
				if IsLocationPassable(bF) then
					return BOT_ACTION_DESIRE_HIGH, bF, "ground", nil
				end
			end
		end
	end
	if mod.IsDoingTormentor(bot) and not mod.IsRealInvisible(bot) then
		local bP = mod.GetTormentorLocation(GetTeam())
		if GetUnitToLocationDistance(bot, bP) > 2000 then
			local bF = mod.VectorTowards(bot:GetLocation(), bP, bv)
			local nInRangeEnemy = mod.GetEnemiesNearLoc(bF, 1200)
			if IsLocationPassable(bF) and #nInRangeEnemy == 0 then
				return BOT_ACTION_DESIRE_HIGH, bF, "ground", nil
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_overwhelming_blink"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_blink"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_swift_blink"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_blink"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_arcane_blink"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_blink"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_cheese"] = function(bm)
	if bot:DistanceFromFountain() < 1200 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local bQ = bot:GetMaxHealth() - bot:GetHealth()
	local bR = bot:GetHealth() / bot:GetMaxHealth()
	local bS = bot:GetMaxMana() - bot:GetMana()
	local bT = bot:GetMana() / bot:GetMaxMana()
	if bQ > 2500 and bS > 1500 or bQ > 2000 and bQ + bS > 3000 or bR < 0.4 and bT < 0.4 or bR < 0.2 or bT < 0.06 then
		if mod.IsGoingOnSomeone(bot) then
			if mod.IsValidHero(be) and mod.IsInRange(bot, be, 2000) and mod.CanCastOnMagicImmune(be) then
				hEffectTarget = bot
				bw = "进攻"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
		if mod.IsRetreating(bot) and bot:WasRecentlyDamagedByAnyHero(4.0) then
			hEffectTarget = bot
			bw = "撤退"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_bloodstone"] = function(bm)
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	if bot:IsSilenced() or bot:GetMana() < bm:GetManaCost() then
		return BOT_ACTION_DESIRE_NONE
	end
	if #bx == 0 and not mod.IsDoingRoshan(bot) and not mod.IsDoingTormentor(bot) then
		return BOT_ACTION_DESIRE_NONE
	end
	if mod.IsInTeamFight(bot, 1200) and #bx >= 2 then
		hEffectTarget = bot
		bw = "Bloodstone: teamfight spell lifesteal"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.IsGoingOnSomeone(bot) and #bx >= 1 then
		hEffectTarget = bot
		bw = "Bloodstone: going on target with spell lifesteal"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.IsDoingRoshan(bot) or mod.IsDoingTormentor(bot) then
		hEffectTarget = bot
		bw = "Bloodstone: Roshan/Tormentor sustain"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_bloodthorn"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_orchid"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_bottle"] = function(bm)
	if bm:GetCurrentCharges() == 0 or bot:HasModifier("modifier_bottle_regeneration") then
		return BOT_ACTION_DESIRE_NONE
	end
	if mod.HasDamageOverTimeDebuff(bot) then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 400 + b8
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bS = bot:GetMaxMana() - bot:GetMana()
	local bQ = bot:OriginalGetMaxHealth() - bot:OriginalGetHealth()
	if bot:HasModifier("modifier_fountain_aura") then
		hEffectTarget = bot
		bw = "在泉水里喝"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if not bot:WasRecentlyDamagedByAnyHero(3.0) then
		if bQ > 150 and bS > 90 then
			hEffectTarget = bot
			bw = "补血补篮"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if bQ > 500 and mod.GetHP(bot) < 0.5 then
			hEffectTarget = bot
			bw = "只补血"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if bS > 280 and mod.GetMP(bot) < 0.4 then
			hEffectTarget = bot
			bw = "只补篮"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_clarity"] = function(bm)
	if bot:DistanceFromFountain() < 2000 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 800 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		mod.GetMP(bot) < 0.4
		and not bot:HasModifier("modifier_clarity_potion")
		and #bx == 0
		and not bot:WasRecentlyDamagedByAnyHero(4.0)
	then
		hEffectTarget = bot
		bw = "净化自己"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if #bx == 0 then
		local bU = mod.GetNearbyHeroes(bot, 600, false, BOT_MODE_NONE)
		local bV = nil
		local bW = 99999
		for aX, bA in pairs(bU) do
			if
				mod.IsValid(bA)
				and bA ~= bot
				and not bA:IsIllusion()
				and not bA:IsChanneling()
				and not bA:HasModifier("modifier_clarity_potion")
				and not bA:WasRecentlyDamagedByAnyHero(4.0)
				and bA:GetMaxMana() - bA:GetMana() > 350
			then
				if bA:GetMana() < bW then
					bV = bA
					bW = bA:GetMana()
				end
			end
		end
		if bV ~= nil then
			hEffectTarget = bV
			bw = "净化队友:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_crimson_guard"] = function(bm)
	if bot:DistanceFromFountain() < 400 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 1200
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local by = mod.GetAllyList(bot, bv)
	for aX, bA in pairs(by) do
		if
			mod.IsValid(bA)
			and bA:OriginalGetHealth() / bA:OriginalGetMaxHealth() < 0.8
			and bA:WasRecentlyDamagedByAnyHero(2.0)
			and not bA:HasModifier("modifier_item_crimson_guard_nostack")
			and #bc > 0
		then
			hEffectTarget = bA
			bw = "救救队友:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	local bX = mod.GetNearbyHeroes(bot, 1000, true, BOT_MODE_NONE)
	local bY = bot:GetNearbyTowers(800, true)
	if #by >= 2 and (#bX + #bY >= 2 or #bX >= 2) then
		for aX, bA in pairs(by) do
			if bA:WasRecentlyDamagedByAnyHero(2.0) and not bA:HasModifier("modifier_item_crimson_guard_nostack") then
				hEffectTarget = bA
				bw = "保护队友:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_cyclone"] = function(bm)
	local bv = 650 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bot:HasModifier("modifier_nyx_assassin_vendetta") then
		return BOT_ACTION_DESIRE_NONE
	end
	if
		mod.IsValid(be)
		and mod.CanCastOnNonMagicImmune(be)
		and abilityItemUsage.IsWithoutSpellShield(be)
		and mod.IsInRange(bot, be, bv + 200)
	then
		if unitName == "npc_dota_hero_invoker" and mod.IsGoingOnSomeone(bot) then
			if mod.IsValidHero(be) and not mod.IsSuspiciousIllusion(be) and mod.GetMP(bot) > 0.5 then
				hEffectTarget = be
				bw = "预设连招:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
		if
			be:HasModifier("modifier_invoker_cold_snap_freeze")
			or be:HasModifier("modifier_invoker_cold_snap")
			or be:HasModifier("modifier_invoker_chaos_meteor_burn")
		then
			return BOT_ACTION_DESIRE_NONE
		end
		if
			be:HasModifier("modifier_teleporting")
			or be:HasModifier("modifier_abaddon_borrowed_time")
			or be:HasModifier("modifier_ursa_enrage")
			or be:HasModifier("modifier_item_satanic_unholy")
			or be:IsChanneling()
		then
			hEffectTarget = be
			bw = "驱散Buff:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if mod.GetHP(be) > 0.49 and mod.IsCastingUltimateAbility(be) then
			hEffectTarget = be
			bw = "打断大招:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if mod.IsRunning(be) and be:GetCurrentMovementSpeed() > 440 then
			hEffectTarget = be
			bw = "阻止逃跑:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.CanCastOnNonMagicImmune(bot) and #bc > 0 then
		if mod.GetHP(bot) < 0.2 and bot:WasRecentlyDamagedByAnyHero(3.0) then
			hEffectTarget = bot
			bw = "撤退:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if bot:IsRooted() or bot:GetPrimaryAttribute() == ATTRIBUTE_INTELLECT and bot:IsSilenced() then
			hEffectTarget = bot
			bw = "解缠绕:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if mod.IsUnitTargetProjectileIncoming(bot, 800) then
			hEffectTarget = bot
			bw = "防御弹道:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_wind_waker"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_cyclone"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_dagon"] = function(bm)
	local bv = bm:GetCastRange() + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv + 100, true, BOT_MODE_NONE)
	local bZ = bm:GetSpecialValueInt("damage")
	if bot:HasModifier("modifier_nyx_assassin_vendetta") then
		return BOT_ACTION_DESIRE_NONE
	end
	for aX, br in pairs(bx) do
		if
			mod.IsValidHero(br)
			and mod.CanCastOnNonMagicImmune(br)
			and abilityItemUsage.IsWithoutSpellShield(br)
			and mod.CanKillTarget(br, bZ, DAMAGE_TYPE_MAGICAL)
		then
			hEffectTarget = br
			bw = "击杀:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanCastOnNonMagicImmune(be)
			and abilityItemUsage.IsWithoutSpellShield(be)
			and mod.IsInRange(bot, be, bv)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_dagon_2"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_dagon"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_dagon_3"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_dagon"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_dagon_4"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_dagon"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_dagon_5"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_dagon"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_diffusal_blade"] = function(bm)
	local bv = 630 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bf == BOT_MODE_RETREAT then
		for aX, br in pairs(bc) do
			if
				mod.IsValid(br)
				and mod.IsMoving(br)
				and mod.IsInRange(br, bot, bv)
				and bot:WasRecentlyDamagedByHero(br, 4.0)
				and br:GetCurrentMovementSpeed() > 200
				and mod.CanCastOnNonMagicImmune(br)
				and abilityItemUsage.IsWithoutSpellShield(br)
				and not mod.IsDisabled(br)
			then
				hEffectTarget = br
				bw = "撤退:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.IsMoving(be)
			and be:GetCurrentMovementSpeed() > 200
			and mod.IsInRange(be, bot, bv)
			and mod.CanCastOnNonMagicImmune(be)
			and abilityItemUsage.IsWithoutSpellShield(be)
			and not mod.IsDisabled(be)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if
		mod.IsValidHero(be)
		and mod.IsInRange(be, bot, bv)
		and mod.CanCastOnNonMagicImmune(be)
		and abilityItemUsage.IsWithoutSpellShield(be)
		and not mod.IsDisabled(be)
		and bot:GetAttackTarget() == be
	then
		hEffectTarget = be
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, "diffusal: in combat"
	end
	local br = bc[1]
	if
		mod.IsValidHero(br)
		and mod.IsInRange(bot, br, bv - 100)
		and mod.CanCastOnNonMagicImmune(br)
		and abilityItemUsage.IsWithoutSpellShield(br)
		and not mod.IsDisabled(br)
		and mod.IsMoving(br)
		and mod.IsRunning(br)
		and br:GetCurrentMovementSpeed() > bot:GetCurrentMovementSpeed() * 0.8
	then
		hEffectTarget = br
		bw = "减速:" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_enchanted_mango"] = function(bm)
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	if bot:GetMana() < 150 then
		hEffectTarget = bot
		bw = "自己吃"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_ethereal_blade"] = function(bm)
	local bv = 800 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanCastOnNonMagicImmune(be)
			and mod.CanCastOnTargetAdvanced(be)
			and mod.IsInRange(bot, be, bv)
		then
			hEffectTarget = be
			bw = "进攻" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_faerie_fire"] = function(bm)
	if bot:DistanceFromFountain() < 1800 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 300 + b8
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		bf == BOT_MODE_RETREAT
		and bot:GetActiveModeDesire() >= BOT_MODE_DESIRE_HIGH
		and bot:WasRecentlyDamagedByAnyHero(3.0)
		and bot:OriginalGetHealth() < 90
	then
		hEffectTarget = bot
		bw = "撤退"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.IsGoingOnSomeone(bot) and mod.GetHP(bot) < 0.3 and mod.IsValidHero(be) and bot:WasRecentlyDamagedByAnyHero(3.0) then
		hEffectTarget = bot
		bw = "进攻"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if
		DotaTime() > 10 * 60
		and bm:GetName() == "item_faerie_fire"
		and bot:GetItemInSlot(6) ~= nil
		and bot:GetMaxHealth() - bot:OriginalGetHealth() > 200
	then
		hEffectTarget = bot
		bw = "自己吃"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_flask"] = function(bm)
	if bot:DistanceFromFountain() < 3000 then
		return BOT_ACTION_DESIRE_NONE
	end
	if mod.HasDamageOverTimeDebuff(bot) then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 900
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local b_ = mod.GetHP(bot)
	if
		b_ < 0.65
		and #bx == 0
		and not bot:WasRecentlyDamagedByAnyHero(2.2)
		and not bot:HasModifier("modifier_filler_heal")
		and not bot:HasModifier("modifier_elixer_healing")
		and not bot:HasModifier("modifier_flask_healing")
		and not bot:HasModifier("modifier_juggernaut_healing_ward_heal")
	then
		hEffectTarget = bot
		bw = "自己吃"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	local bU = mod.GetAlliesNearLoc(bot:GetLocation(), 700)
	local c0 = nil
	local c1 = 99999
	for aX, bA in pairs(bU) do
		if
			mod.IsValid(bA)
			and bA ~= bot
			and not bA:HasModifier("modifier_filler_heal")
			and not bA:HasModifier("modifier_elixer_healing")
			and not bA:HasModifier("modifier_flask_healing")
			and not bA:HasModifier("modifier_juggernaut_healing_ward_heal")
			and not bA:WasRecentlyDamagedByAnyHero(3.0)
			and not bA:IsIllusion()
			and not bA:IsChanneling()
			and mod.GetHP(bA) < 0.6
		then
			if bA:OriginalGetHealth() < c1 then
				c0 = bA
				c1 = bA:OriginalGetHealth()
			end
		end
	end
	if c0 ~= nil and #bx == 0 then
		hEffectTarget = c0
		bw = "给队友贴:" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
local function c2(bm, c3, c4, c5, c6, c7, c8, c9, ca)
	if bot:DistanceFromFountain() < c7 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bq = "unit"
	local bx = mod.GetNearbyHeroes(bot, 900, true, BOT_MODE_NONE)
	local bR = mod.GetHP(bot)
	local bT = bot:GetMaxMana() > 0 and bot:GetMana() / bot:GetMaxMana() or 1
	if c8 and DotaTime() > 30 * 60 and mod.IsCore(bot) then
		return BOT_ACTION_DESIRE_NONE
	end
	if c9 then
		if bR < 0.35 or bR < 0.5 and bT < 0.3 then
			if mod.IsRetreating(bot) or mod.IsGoingOnSomeone(bot) or #bx >= 1 then
				return BOT_ACTION_DESIRE_HIGH, bot, bq, "Emergency self (" .. c3 .. ")"
			end
		end
	end
	if
		(bR < c4 or bT < c5)
		and #bx == 0
		and not bot:WasRecentlyDamagedByAnyHero(2.2)
		and not bot:HasModifier("modifier_flask_healing")
		and not bot:HasModifier("modifier_filler_heal")
	then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Self heal (" .. c3 .. ")"
	end
	local bU = mod.GetAlliesNearLoc(bot:GetLocation(), 700)
	local cb = nil
	local cc = 0
	for aX, bA in pairs(bU) do
		if
			mod.IsValid(bA)
			and bA ~= bot
			and not bA:IsIllusion()
			and not bA:HasModifier("modifier_flask_healing")
			and not bA:HasModifier("modifier_filler_heal")
			and (c9 or not bA:WasRecentlyDamagedByAnyHero(3.0))
		then
			local cd = bA:GetHealth() / bA:GetMaxHealth()
			local ce = bA:GetMaxMana() > 0 and bA:GetMana() / bA:GetMaxMana() or 1
			if cd < c6 or ce < c6 then
				local cf = 1 - cd + (1 - ce) * 0.5
				if ca and mod.IsCore(bA) then
					cf = cf * 1.5
				end
				if cf > cc then
					cb = bA
					cc = cf
				end
			end
		end
	end
	if cb ~= nil and (c9 or #bx == 0) then
		return BOT_ACTION_DESIRE_HIGH, cb, bq, "Heal ally (" .. c3 .. "): " .. mod.Chat.GetNormName(cb)
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_famango"] = function(cg)
	return c2(cg, "lotus", 0.7, 0.5, 0.6, 3000, true, false, false)
end
abilityItemUsage.ConsiderItemDesire["item_great_famango"] = function(cg)
	return c2(cg, "great lotus", 0.6, 0.4, 0.5, 3000, true, false, false)
end
abilityItemUsage.ConsiderItemDesire["item_greater_famango"] = function(cg)
	return c2(cg, "greater lotus", 0.5, 0.3, 0.5, 1200, false, true, true)
end
abilityItemUsage.ConsiderItemDesire["item_force_staff"] = function(bm)
	local bv = 550 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bot:HasModifier("modifier_nyx_assassin_vendetta") then
		return BOT_ACTION_DESIRE_NONE
	end
	if bot:HasModifier("modifier_furion_sprout_damage") then
		hEffectTarget = bot
		bw = "解开先知的树框" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	local bU = mod.GetAlliesNearLoc(bot:GetLocation(), 600)
	for aX, bA in pairs(bU) do
		if bA ~= nil and bA:IsAlive() and mod.CanCastOnNonMagicImmune(bA) then
			local ch = mod.GetNearbyHeroes(bA, 1200, true, BOT_MODE_NONE)
			if
				#ch >= 1
				and not bA:IsInvisible()
				and bA:GetActiveMode() == BOT_MODE_RETREAT
				and bA:IsFacingLocation(GetAncient(team):GetLocation(), 30)
				and bA:DistanceFromFountain() > 600
				and bA:WasRecentlyDamagedByAnyHero(4.0)
			then
				hEffectTarget = bA
				bw = "帮队友撤退" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if mod.IsGoingOnSomeone(bA) then
				local ci = mod.GetProperTarget(bA)
				if
					mod.IsValidHero(ci)
					and bA:IsFacingLocation(ci:GetLocation(), 15)
					and mod.CanCastOnNonMagicImmune(ci)
					and GetUnitToUnitDistance(ci, bA) > bA:GetAttackRange() + 50
					and GetUnitToUnitDistance(ci, bA) < bA:GetAttackRange() + 700
					and not ci:IsFacingLocation(bA:GetLocation(), 40)
					and mod.GetEnemyCount(bA, 1600) <= 3
				then
					hEffectTarget = bA
					bw = "帮队友进攻" .. mod.Chat.GetNormName(hEffectTarget)
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
			if mod.IsStuck(bA) or bA:HasModifier("modifier_furion_sprout_damage") then
				hEffectTarget = bA
				bw = "队友卡地形了" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	for aX, bA in pairs(bU) do
		if
			bA ~= nil
			and bA:IsAlive()
			and bA:GetUnitName() == "npc_dota_hero_crystal_maiden"
			and mod.CanCastOnNonMagicImmune(bA)
			and (bA:IsInvisible() or bA:GetHealth() / bA:GetMaxHealth() > 0.8)
			and (bA:IsChanneling() and not bA:HasModifier("modifier_teleporting"))
		then
			local cj = mod.GetNearbyHeroes(bA, 1200, true, BOT_MODE_NONE)
			for aX, br in pairs(cj) do
				if
					br ~= nil
					and br:IsAlive()
					and mod.CanCastOnNonMagicImmune(br)
					and GetUnitToUnitDistance(br, bA) > 835
					and bA:IsFacingLocation(br:GetLocation(), 30)
				then
					hEffectTarget = bA
					bw = "推冰女"
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
	end
	if bot:DistanceFromFountain() < 2600 then
		for aX, br in pairs(bc) do
			if
				mod.IsValidHero(br)
				and mod.CanCastOnMagicImmune(br)
				and br:IsFacingLocation(GetAncient(team):GetLocation(), 40)
				and GetUnitToLocationDistance(br, GetAncient(team):GetLocation()) < 1200
			then
				hEffectTarget = br
				bw = "推人入泉" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) and #bU >= 2 then
		if
			mod.IsValidHero(be)
			and mod.IsInRange(bot, be, bv)
			and mod.CanCastOnNonMagicImmune(be)
			and abilityItemUsage.IsWithoutSpellShield(be)
		then
			local ck = mod.GetCenterOfUnits(bU)
			if be:IsFacingLocation(ck, 28) and GetUnitToLocationDistance(bot, ck) >= 500 then
				hEffectTarget = be
				bw = "推敌人靠近自己" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_ghost"] = function(bm)
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bot:GetAttackTarget() == nil or bot:GetHealth() < 500 then
		for aX, br in pairs(bc) do
			if
				mod.IsValidHero(br)
				and mod.CanCastOnMagicImmune(br)
				and mod.IsInRange(bot, br, br:GetAttackRange() + 100)
				and br:GetAttackTarget() == bot
				and bot:WasRecentlyDamagedByHero(br, 2.0)
				and br:GetAttackDamage() > bot:GetAttackDamage()
			then
				hEffectTarget = br
				bw = "撤退" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_crellas_crozier"] = function(bm)
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	if bot:GetAttackTarget() == nil or bot:GetHealth() < 500 then
		for aX, br in pairs(bc) do
			if
				mod.IsValidHero(br)
				and mod.CanCastOnMagicImmune(br)
				and mod.IsInRange(bot, br, br:GetAttackRange() + 100)
				and br:GetAttackTarget() == bot
				and bot:WasRecentlyDamagedByHero(br, 2.0)
				and br:GetAttackDamage() > bot:GetAttackDamage()
			then
				hEffectTarget = br
				bw = "撤退" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_glimmer_cape"] = function(bm)
	local bv = 800 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	if
		bot:DistanceFromFountain() > 600
		and #bd == 0
		and not bot:HasModifier("modifier_item_dustofappearance")
		and not bot:HasModifier("modifier_slardar_amplify_damage")
		and not bot:HasModifier("modifier_item_glimmer_cape")
		and not bot:IsInvulnerable()
		and not bot:IsMagicImmune()
	then
		if bot:IsSilenced() or bot:IsRooted() or mod.IsStunProjectileIncoming(bot, 1000) then
			hEffectTarget = bot
			bw = "自己被缠绕或沉默了"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if
			mod.IsRetreating(bot)
				and bot:GetActiveModeDesire() >= BOT_MODE_DESIRE_HIGH
				and not bot:HasModifier("modifier_fountain_aura")
			or be == nil and #bc > 0 and mod.GetHP(bot) < 0.36 + 0.09 * #bc
		then
			hEffectTarget = bot
			bw = "自己撤退"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		local bU = mod.GetNearbyHeroes(bot, bv, false, BOT_MODE_NONE)
		for aX, bA in pairs(bU) do
			if
				mod.IsValid(bA)
				and not bA:IsIllusion()
				and not bA:IsMagicImmune()
				and not bA:IsInvulnerable()
				and not bA:IsInvisible()
				and bA:DistanceFromFountain() > 600
				and not bA:HasModifier("modifier_item_glimmer_cape")
				and not bA:HasModifier("modifier_item_dustofappearance")
				and not bA:HasModifier("modifier_slardar_amplify_damage")
				and not bA:HasModifier("modifier_arc_warden_tempest_double")
			then
				local cl = bA:GetNearbyTowers(888, true)
				if #cl == 0 then
					if
						mod.GetHP(bA) < 0.35 + 0.05 * #bc
						and mod.IsRetreating(bA)
						and bA:WasRecentlyDamagedByAnyHero(4.0)
					then
						hEffectTarget = bA
						bw = "保护队友撤退:" .. mod.Chat.GetNormName(hEffectTarget)
						return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
					end
					if mod.IsDisabled(bA) or mod.IsStunProjectileIncoming(bA, 1000) then
						hEffectTarget = bA
						bw = "保护被控队友:" .. mod.Chat.GetNormName(hEffectTarget)
						return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
					end
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_mekansm"] = function(bm)
	local bv = 1200
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bU = mod.GetAllyList(bot, bv)
	for aX, bA in pairs(bU) do
		if bA ~= nil and bA:IsAlive() and mod.GetHP(bA) < 0.45 and #bc > 0 then
			hEffectTarget = bA
			bw = "治疗队友" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	local cm = 0
	for aX, bA in pairs(bU) do
		if bA ~= nil and bA:GetMaxHealth() - bA:GetHealth() > 400 then
			cm = cm + 1
			if cm >= 2 and bA:GetHealth() / bA:GetMaxHealth() < 0.55 then
				hEffectTarget = bA
				bw = "治疗二队友:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if cm >= 3 then
				hEffectTarget = bA
				bw = "治疗多个队友:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if
		bot:GetHealth() / bot:GetMaxHealth() < 0.5
		or bot:IsSilenced()
		or bot:IsRooted()
		or bot:HasModifier("modifier_item_urn_damage")
		or bot:HasModifier("modifier_item_spirit_vessel_damage")
	then
		hEffectTarget = bot
		bw = "治疗自己:" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_guardian_greaves"] = function(bm)
	local bv = 1200
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bU = mod.GetAllyList(bot, bv)
	for aX, bA in pairs(bU) do
		if bA ~= nil and bA:IsAlive() and mod.GetHP(bA) < 0.45 and #bc > 0 then
			hEffectTarget = bA
			bw = "治疗队友" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	local cm = 0
	for aX, bA in pairs(bU) do
		if bA ~= nil and bA:GetMaxHealth() - bA:GetHealth() > 400 then
			cm = cm + 1
			if cm >= 2 and bA:GetHealth() / bA:GetMaxHealth() < 0.55 then
				hEffectTarget = bA
				bw = "治疗二队友:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if cm >= 3 then
				hEffectTarget = bA
				bw = "治疗多个队友:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if
		bot:GetHealth() / bot:GetMaxHealth() < 0.5
		or bot:IsSilenced()
		or bot:IsRooted()
		or bot:HasModifier("modifier_item_urn_damage")
		or bot:HasModifier("modifier_item_spirit_vessel_damage")
	then
		hEffectTarget = bot
		bw = "治疗自己:" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	local bz = 0
	for aX, bA in pairs(bU) do
		if bA ~= nil and bA:GetMaxMana() - bA:GetMana() > 400 then
			bz = bz + 1
		end
		if bz >= 2 and bot:GetMana() / bot:GetMaxMana() < 0.2 then
			hEffectTarget = bA
			bw = "回蓝二队友:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if bz >= 3 then
			hEffectTarget = bA
			bw = "回蓝多个队友:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	local cn = bot:GetNearbyLaneCreeps(1200, false)
	if #cn >= 9 then
		local bG = bot:FindAoELocation(false, false, bot:GetLocation(), 100, 1100, 0, 200)
		if bG.count >= 6 and GetUnitToLocationDistance(bot, bG.targetloc) <= 200 then
			hEffectTarget = bot
			bw = "治疗小兵们:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_hand_of_midas"] = function(bm)
	local bv = 990 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	if #bc >= 1 then
		bv = 628
	end
	local co = bot:GetNearbyCreeps(bv, true)
	local cp = nil
	local cq = 0
	for aX, b2 in pairs(co) do
		if mod.IsValid(b2) and not b2:IsMagicImmune() and not b2:IsAncientCreep() then
			if b2:GetLevel() > cq then
				cq = b2:GetLevel()
				cp = b2
			end
		end
	end
	if cp ~= nil then
		hEffectTarget = cp
		bw = "点金小兵:" .. hEffectTarget:GetUnitName()
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_heavens_halberd"] = function(bm)
	local bv = 700 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local cr = nil
	local cs = 0
	for aX, br in pairs(bx) do
		if
			mod.IsValidHero(br)
			and not br:IsDisarmed()
			and not mod.IsDisabled(br)
			and mod.CanCastOnNonMagicImmune(br)
			and abilityItemUsage.IsWithoutSpellShield(br)
			and br:GetAttackTarget() ~= nil
			and (br:GetPrimaryAttribute() ~= ATTRIBUTE_INTELLECT or br:GetAttackDamage() > 180)
		then
			local ct = br:GetEstimatedDamageToTarget(false, bot, 3.0, DAMAGE_TYPE_PHYSICAL)
			if ct > cs then
				cs = ct
				cr = br
			end
		end
	end
	if cr ~= nil then
		hEffectTarget = cr
		bw = "缴械敌人:" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if bot:GetActiveMode() == BOT_MODE_ROSHAN then
		local be = bot:GetAttackTarget()
		if mod.IsRoshan(be) and not mod.IsDisabled(be) and not be:IsDisarmed() then
			hEffectTarget = be
			bw = "缴械肉山"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_helm_of_the_dominator"] = function(bm)
	local bv = 1000 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	for aX, aR in pairs(GetUnitList(UNIT_LIST_ALLIED_CREEPS)) do
		if mod.IsValid(aR) and aR:HasModifier("modifier_dominated") and aR:IsAncientCreep() then
			return BOT_ACTION_DESIRE_NONE, hEffectTarget, "sCastType", bw
		end
	end
	local cu = 0
	local cv = nil
	local co = bot:GetNearbyCreeps(bv, true)
	if #co >= 2 then
		for aX, b2 in pairs(co) do
			if mod.IsValid(b2) then
				local cw = b2:GetHealth()
				if
					cw > cu
					and b2:GetHealth() / b2:GetMaxHealth() > 0.75
					and (not b2:IsAncientCreep() or bm:GetName() == "item_helm_of_the_overlord")
					and not mod.IsKeyWordUnit("siege", b2)
				then
					cv = b2
					cu = cw
				end
			end
		end
	end
	if cv ~= nil then
		hEffectTarget = cv
		bw = "支配:" .. hEffectTarget:GetUnitName()
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_helm_of_the_overlord"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_helm_of_the_dominator"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_hood_of_defiance"] = function(bm)
	if bot:HasModifier("modifier_item_pipe_barrier") or mod.GetHP(bot) > 0.88 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 1000
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if #bx > 0 then
		hEffectTarget = bot
		bw = "套盾"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_holy_locket"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_magic_wand"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_hurricane_pike"] = function(bm)
	local bv = 800 + b8
	local cx = 450 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, cx, true, BOT_MODE_NONE)
	if bf == BOT_MODE_RETREAT and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_HIGH then
		for aX, br in pairs(bc) do
			if mod.IsInRange(bot, br, cx) and mod.CanCastOnNonMagicImmune(br) then
				hEffectTarget = br
				bw = "撤退了推敌人"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
		if bot:IsFacingLocation(GetAncient(team):GetLocation(), 20) and bot:DistanceFromFountain() > 600 and #bc >= 1 then
			hEffectTarget = bot
			bw = "撤退了推自己"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanCastOnNonMagicImmune(be)
			and GetUnitToUnitDistance(be, bot) > bot:GetAttackRange() + 100
			and GetUnitToUnitDistance(be, bot) < bot:GetAttackRange() + 700
			and GetUnitToUnitDistance(be, bot) < GetUnitToLocationDistance(bot, mod.GetCorrectLoc(be, 1.0)) - 100
			and bot:IsFacingLocation(be:GetLocation(), 20)
			and not be:IsFacingLocation(bot:GetLocation(), 120)
			and mod.GetEnemyCount(bot, 1600) <= 2
		then
			hEffectTarget = bot
			bw = "进攻" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.HasItem(bot, "item_hurricane_pike") then
		for aX, br in pairs(bc) do
			if
				br ~= nil
				and mod.CanCastOnNonMagicImmune(br)
				and GetUnitToUnitDistance(br, bot) <= cx
				and mod.CanCastOnNonMagicImmune(br)
			then
				bot:SetTarget(br)
				hEffectTarget = br
				bw = "推开" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	local bU = mod.GetNearbyHeroes(bot, bv, false, BOT_MODE_NONE)
	for aX, bA in pairs(bU) do
		if
			bA ~= nil
			and bA:IsAlive()
			and bA:GetUnitName() == "npc_dota_hero_crystal_maiden"
			and mod.CanCastOnNonMagicImmune(bA)
			and abilityItemUsage.IsWithoutSpellShield(bA)
			and (bA:IsInvisible() or bA:GetHealth() / bA:GetMaxHealth() > 0.8)
			and (bA:IsChanneling() and not bA:HasModifier("modifier_teleporting"))
		then
			local cj = mod.GetNearbyHeroes(bA, 1200, true, BOT_MODE_NONE)
			for aX, br in pairs(cj) do
				if
					br ~= nil
					and br:IsAlive()
					and mod.CanCastOnNonMagicImmune(br)
					and GetUnitToUnitDistance(br, bA) > 835
					and bA:IsFacingLocation(br:GetLocation(), 30)
				then
					hEffectTarget = bA
					bw = "推CM"
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_invis_sword"] = function(bm)
	if
		bot:IsInvisible()
		or #bd > 0
		or bot:HasModifier("modifier_item_dustofappearance")
		or bot:HasModifier("modifier_slardar_amplify_damage")
	then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsRetreating(bot) and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE and #bc > 0 then
		hEffectTarget = bot
		bw = "撤退了"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.GetHP(bot) < 0.166 and (#bc > 0 or bot:WasRecentlyDamagedByAnyHero(5.0)) then
		hEffectTarget = bot
		bw = "残血了"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanCastOnMagicImmune(be)
			and not mod.IsInRange(bot, be, be:GetCurrentVisionRange())
			and mod.IsInRange(bot, be, 2600)
		then
			local cy = bot:GetNearbyLaneCreeps(800, true)
			if #cy == 0 and #bc == 0 then
				hEffectTarget = be
				bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_lotus_orb"] = function(bm)
	local bv = 1000 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local cz = mod.GetNearbyHeroes(bot, bv, false, BOT_MODE_NONE)
	for aX, bA in pairs(cz) do
		if
			mod.IsValid(bA)
			and not bA:IsIllusion()
			and not bA:IsMagicImmune()
			and not bA:IsInvulnerable()
			and not bA:HasModifier("modifier_item_lotus_orb_active")
			and not bA:HasModifier("modifier_antimage_spell_shield")
		then
			if mod.IsUnitTargetProjectileIncoming(bA, 800) then
				hEffectTarget = bA
				bw = "反弹弹道"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if
				bA:IsRooted()
				or bA:IsSilenced() and not bA:HasModifier("modifier_item_mask_of_madness_berserk")
				or bA:IsDisarmed() and not bA:HasModifier("modifier_oracle_fates_edict")
			then
				hEffectTarget = bA
				bw = "驱散队友:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if mod.IsWillBeCastUnitTargetSpell(bA, 1200) then
				hEffectTarget = bA
				bw = "给队友反弹技能:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_magic_stick"] = function(bm)
	if bm:GetCurrentCharges() <= 0 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bq = "none"
	local bx = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	local ax = #bx
	local cA = mod.GetHP(bot)
	local cB = mod.GetMP(bot)
	local cC = bm:GetCurrentCharges()
	if cA < 0.25 and cC >= 1 then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Stick: emergency"
	end
	if mod.IsRetreating(bot) and cA < 0.6 and cC >= 2 then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Stick: retreat"
	end
	if ax >= 1 and cC >= 1 and (cA < 0.6 or cB < 0.35) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Stick: fight"
	end
	if cC >= 5 and ax == 0 and (cA < 0.7 or cB < 0.5) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Stick: proactive heal"
	end
	if cC >= 10 and (cA < 0.85 or cB < 0.75) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Stick: max charges"
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_magic_wand"] = function(bm)
	if bm:GetCurrentCharges() <= 0 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bq = "none"
	if bm:GetName() == "item_holy_locket" then
		bq = "unit"
	end
	local bx = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	local ax = #bx
	local cA = mod.GetHP(bot)
	local cB = mod.GetMP(bot)
	local cC = bm:GetCurrentCharges()
	local cD = mod.IsRetreating(bot)
	if cA < 0.25 and cC >= 1 then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Wand: emergency"
	end
	if cD and cA < 0.6 and cC >= 2 then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Wand: retreat"
	end
	if ax >= 1 and cC >= 1 and (cA < 0.6 or cB < 0.3) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Wand: fight"
	end
	if cC >= 5 and ax == 0 and (cA < 0.75 or cB < 0.5) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Wand: proactive heal"
	end
	if cC >= 10 and (cA < 0.8 or cB < 0.6) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Wand: high charges"
	end
	if cC >= 20 and (cA < 0.9 or cB < 0.75) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "Wand: max charges"
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_manta"] = function(bm)
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local cE = mod.GetNearbyHeroes(bot, 1000, false, BOT_MODE_ATTACK)
	local bX = mod.GetNearbyHeroes(bot, 1000, true, BOT_MODE_NONE)
	local bY = bot:GetNearbyTowers(800, true)
	local cF = bot:GetNearbyBarracks(600, true)
	local cG = bot:GetNearbyLaneCreeps(1000, false)
	local cH = bot:GetNearbyLaneCreeps(800, true)
	if mod.IsPushing(bot) then
		if (#bY >= 1 or #cF >= 1) and #cG >= 1 then
			hEffectTarget = bot
			bw = "推进"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if
		mod.IsGoingOnSomeone(bot)
		and mod.IsValidHero(be)
		and mod.CanCastOnMagicImmune(be)
		and mod.IsInRange(bot, be, bot:GetAttackRange() + 80)
	then
		hEffectTarget = be
		bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if
		bot:IsRooted()
		or bot:IsSilenced() and not bot:HasModifier("modifier_item_mask_of_madness_berserk")
		or bot:HasModifier("modifier_item_solar_crest_armor_reduction")
		or bot:HasModifier("modifier_item_medallion_of_courage_armor_reduction")
		or bot:HasModifier("modifier_item_spirit_vessel_damage")
		or bot:HasModifier("modifier_dragonknight_breathefire_reduction")
		or bot:HasModifier("modifier_slardar_amplify_damage")
		or bot:HasModifier("modifier_item_dustofappearance")
	then
		hEffectTarget = bot
		bw = "解Buff"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if
		not bot:IsMagicImmune()
		and not bot:HasModifier("modifier_antimage_spell_shield")
		and not bot:HasModifier("modifier_item_sphere_target")
		and not bot:HasModifier("modifier_item_lotus_orb_active")
		and mod.IsNotAttackProjectileIncoming(bot, 70)
	then
		hEffectTarget = bot
		bw = "躲弹道"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.IsRetreating(bot) and bX[1] ~= nil and bot:DistanceFromFountain() > 600 then
		hEffectTarget = bot
		bw = "撤退了"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if #cH >= 8 then
		hEffectTarget = bot
		bw = "刷小兵"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if
		bot:WasRecentlyDamagedByAnyHero(5.0)
		and bot:GetHealth() / bot:GetMaxHealth() < 0.18
		and bot:DistanceFromFountain() > 800
	then
		hEffectTarget = bot
		bw = "残血了"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_mjollnir"] = function(bm)
	local bv = 800 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local cI = mod.GetNearbyHeroes(bot, bv + 100, false, BOT_MODE_NONE)
	if mod.IsInTeamFight(bot, 900) then
		local cJ = nil
		local cK = 1
		for aX, bA in pairs(cI) do
			if mod.IsValid(bA) and not bA:IsIllusion() and not bA:HasModifier("modifier_item_mjollnir_static") then
				local ay = 0
				local nEnemyHeroes = mod.GetNearbyHeroes(bA, 1400, true, BOT_MODE_NONE)
				local cL = bA:GetNearbyCreeps(1000, true)
				for aX, aR in pairs(nEnemyHeroes) do
					if aR ~= nil and aR:IsAlive() and aR:GetAttackTarget() == bA then
						ay = ay + 1
					end
				end
				for aX, aR in pairs(cL) do
					if aR ~= nil and aR:IsAlive() and aR:GetAttackTarget() == bA then
						ay = ay + 1
					end
				end
				if ay > cK then
					cK = ay
					cJ = bA
				end
			end
		end
		if cJ ~= nil then
			hEffectTarget = cJ
			bw = "团战中套电锤给队友:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.IsValidHero(be) then
		local cM = mod.GetAlliesNearLoc(be:GetLocation(), 1400)
		if mod.IsValid(cM[1]) then
			local cJ = nil
			local cN = 9999
			for aX, bA in pairs(cM) do
				if
					mod.IsValid(bA)
					and GetUnitToUnitDistance(bot, bA) < bv + 200
					and GetUnitToUnitDistance(be, bA) < cN
					and not bA:HasModifier("modifier_item_mjollnir_static")
				then
					cJ = bA
					cN = GetUnitToUnitDistance(be, bA)
				end
			end
			if cJ ~= nil then
				hEffectTarget = cJ
				bw = "攻击前套电锤给队友:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if bc[1] == nil then
		local cO = bot:GetNearbyLaneCreeps(1000, false)
		local cL = bot:GetNearbyLaneCreeps(1000, true)
		if #cO >= 1 and #cL == 0 then
			local cp = nil
			local cN = 0
			for aX, b2 in pairs(cO) do
				if mod.IsValid(b2) and mod.GetHP(b2) > 0.6 and b2:DistanceFromFountain() > cN then
					cp = b2
					cN = b2:DistanceFromFountain()
				end
			end
			if cp ~= nil then
				hEffectTarget = cp
				bw = "给前排小兵套上"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if mod.IsValidHero(bc[1]) and bc[1]:GetAttackTarget() == bot then
		if not bot:HasModifier("modifier_item_mjollnir_static") then
			hEffectTarget = bot
			bw = "给自己套上"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_mask_of_madness"] = function(bm)
	if unitName == "npc_dota_hero_drow_ranger" then
		return BOT_ACTION_DESIRE_NONE
	end
	local cP = bot:GetAttackTarget()
	local bv = bot:GetAttackRange() + 100
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	if
		(mod.IsValid(cP) or mod.IsValidBuilding(cP))
		and mod.CanBeAttacked(cP)
		and mod.IsInRange(bot, cP, bv)
		and (
			not mod.CanKillTarget(cP, bot:GetAttackDamage() * 2, DAMAGE_TYPE_PHYSICAL)
			or mod.GetAroundTargetEnemyUnitCount(bot, bv) >= 2
		)
	then
		local cQ = mod.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE)
		if cP:IsHero() or #cQ == 0 and not bot:WasRecentlyDamagedByAnyHero(2.0) then
			if
				#cQ == 0
				or (
					unitName ~= "npc_dota_hero_sniper"
					or unitName ~= "npc_dota_hero_medusa"
					or unitName ~= "npc_dota_hero_faceless_void" and mod.GetUltimateAbility(bot):GetCooldown() > 0
				)
			then
				bot:SetTarget(cP)
				hEffectTarget = cP
				bw = "启动"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_medallion_of_courage"] = function(bm)
	local bv = 900 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and not be:HasModifier("modifier_item_solar_crest_armor_reduction")
			and not be:HasModifier("modifier_item_medallion_of_courage_armor_reduction")
			and mod.CanCastOnNonMagicImmune(be)
			and not be:IsAncientCreep()
			and (
				mod.IsInRange(bot, be, bot:GetAttackRange() + 150)
				or mod.IsInRange(bot, be, 1000) and mod.GetAroundTargetOtherAllyHeroCount(bot, be, 600) >= 1
			)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if #bc == 0 then
		if
			mod.IsValid(be)
			and not be:HasModifier("modifier_item_solar_crest_armor_reduction")
			and not be:HasModifier("modifier_item_medallion_of_courage_armor_reduction")
			and not be:HasModifier("modifier_fountain_glyph")
			and not mod.CanKillTarget(be, bot:GetAttackDamage() * 2.38, DAMAGE_TYPE_PHYSICAL)
			and mod.IsInRange(bot, be, bot:GetAttackRange() + 150)
		then
			hEffectTarget = be
			bw = "刷小兵:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	local bU = mod.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE)
	for aX, bA in pairs(bU) do
		if
			bA ~= bot
			and mod.IsValidHero(bA)
			and not bA:IsIllusion()
			and mod.CanCastOnNonMagicImmune(bA)
			and not bA:HasModifier("modifier_item_solar_crest_armor_addition")
			and not bA:HasModifier("modifier_item_medallion_of_courage_armor_addition")
			and not bA:HasModifier("modifier_arc_warden_tempest_double")
			and (
				mod.IsDisabled(bA)
				or mod.GetHP(bA) < 0.35 and #bc > 0 and bA:WasRecentlyDamagedByAnyHero(2.0)
				or mod.IsValidHero(bA:GetAttackTarget())
					and GetUnitToUnitDistance(bA, bA:GetAttackTarget()) <= bA:GetAttackRange()
					and #bc == 0
			)
		then
			hEffectTarget = bA
			bw = "救队友:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_moon_shard"] = function(bm)
	if bot:GetNetWorth() < 14000 or mod2.CountBackpackEmptySpace(bot) >= 4 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 2000
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	if not bot:HasModifier("modifier_item_moon_shard_consumed") then
		if bot.moonSharedTime == nil then
			bot.moonSharedTime = DotaTime()
		elseif bot.moonSharedTime < DotaTime() - 2.0 then
			bot.moonSharedTime = nil
			hEffectTarget = bot
			bw = "自己吃"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	local cR = nil
	local cS = 0
	for i8 = 1, #GetTeamPlayers(GetTeam()) do
		local cT = GetTeamMember(i8)
		if
			cT ~= nil
			and cT:IsAlive()
			and cT:GetAttackDamage() > cS
			and not cT:HasModifier("modifier_item_moon_shard_consumed")
		then
			cR = cT
			cS = cT:GetAttackDamage()
		end
	end
	if cR ~= nil then
		if bot.moonSharedTime == nil then
			bot.moonSharedTime = DotaTime()
		elseif bot.moonSharedTime < DotaTime() - 3.0 then
			bot.moonSharedTime = nil
			hEffectTarget = cR
			bw = "给队友"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_necronomicon"] = function(bm)
	local bv = 750
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if be ~= nil and be:IsAlive() and mod.IsInRange(bot, be, 1000) then
		hEffectTarget = be
		bw = "进攻"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_necronomicon_2"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_necronomicon"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_necronomicon_3"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_necronomicon"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_nullifier"] = function(bm)
	local bv = 800 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanCastOnNonMagicImmune(be)
			and mod.CanCastOnTargetAdvanced(be)
			and mod.IsInRange(be, bot, bv)
			and not be:HasModifier("modifier_item_nullifier_mute")
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_orchid"] = function(bm)
	local bv = 900 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	for aX, br in pairs(bx) do
		if mod.IsValid(br) and mod.CanCastOnNonMagicImmune(br) and abilityItemUsage.IsWithoutSpellShield(br) then
			if br:IsChanneling() or br:IsCastingAbility() then
				hEffectTarget = br
				bw = "打断:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if mod.IsRetreating(bot) then
				if not mod.IsDisabled(br) then
					hEffectTarget = br
					bw = "撤退:" .. mod.Chat.GetNormName(hEffectTarget)
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.IsInRange(bot, be, bv)
			and not mod.IsDisabled(be)
			and mod.CanCastOnNonMagicImmune(be)
			and abilityItemUsage.IsWithoutSpellShield(be)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_phase_boots"] = function(bm)
	local bq = "none"
	local bx = mod.GetNearbyHeroes(bot, 800, true, BOT_MODE_NONE)
	local cU = bot:GetCurrentActionType()
	if
		cU == BOT_ACTION_TYPE_MOVE_TO
		or cU == BOT_ACTION_TYPE_MOVE_TO_DIRECTLY
		or cU == BOT_ACTION_TYPE_ATTACK_MOVE
		or mod.IsRunning(bot)
	then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "phase: moving"
	end
	if mod.IsGoingOnSomeone(bot) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "phase: chasing"
	end
	if mod.IsRetreating(bot) then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "phase: retreat"
	end
	if #bx > 0 then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, "phase: near enemy"
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_pipe"] = function(bm)
	local bv = 1000
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local by = mod.GetNearbyHeroes(bot, 1200, false, BOT_MODE_NONE)
	for aX, bA in pairs(by) do
		if mod.IsValid(bA) and not bA:IsIllusion() and bA:GetHealth() / bA:GetMaxHealth() < 0.4 and #bc > 0 then
			hEffectTarget = bA
			bw = "保护队友:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	local cV = mod.GetNearbyHeroes(bot, 1200, false, BOT_MODE_NONE)
	local bX = mod.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE)
	local cW = bot:GetNearbyTowers(1200, true)
	if #cV >= 2 and #bX >= 2 or #bX >= 2 and #cV + #cW >= 2 then
		hEffectTarget = bot
		bw = "保护团队"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_power_treads"] = function(bm)
	if defaultItem then
		return 0
	end
	local cX = bm:GetPowerTreadsStat()
	if cX == ATTRIBUTE_INTELLECT then
		cX = ATTRIBUTE_AGILITY
	elseif cX == ATTRIBUTE_AGILITY then
		cX = ATTRIBUTE_INTELLECT
	end
	if
		(
			bot:HasModifier("modifier_flask_healing")
			or bot:HasModifier("modifier_clarity_potion")
			or bot:HasModifier("modifier_item_urn_heal")
			or bot:HasModifier("modifier_item_spirit_vessel_heal")
			or bot:HasModifier("modifier_bottle_regeneration")
		)
		and not mod.IsGoingOnSomeone(bot)
		and not mod.IsRetreating(bot)
		and not bot:WasRecentlyDamagedByAnyHero(5.0)
	then
		if cX ~= ATTRIBUTE_AGILITY then
			bb = DotaTime()
			return BOT_ACTION_DESIRE_HIGH, nil, "none"
		end
	elseif
		mod.IsRetreating(bot) and not mod.IsRealInvisible(bot) and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE
		or mod.IsNotAttackProjectileIncoming(bot, 1200)
		or bf == BOT_MODE_EVASIVE_MANEUVERS
		or bot:HasModifier("modifier_sniper_assassinate")
		or mod.GetHP(bot) < 0.2
		or cX == ATTRIBUTE_STRENGTH and mod.GetHP(bot) < 0.3
	then
		if cX ~= ATTRIBUTE_STRENGTH then
			bb = DotaTime()
			return BOT_ACTION_DESIRE_HIGH, nil, "none"
		end
	elseif mod.IsGoingOnSomeone(bot) then
		if mod.ShouldSwitchPTStat(bot, bm) and bb < DotaTime() - 0.2 then
			return BOT_ACTION_DESIRE_HIGH, nil, "none"
		end
	elseif mod.ShouldSwitchPTStat(bot, bm) and bb < DotaTime() - 0.2 then
		return BOT_ACTION_DESIRE_HIGH, nil, "none"
	end
	return BOT_ACTION_DESIRE_NONE
end
local cY = 0
abilityItemUsage.ConsiderItemDesire["item_quelling_blade"] = function(bm)
	local bv = 450 + b8
	local bq = "tree"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bot:HasModifier("modifier_furion_sprout_damage") then
		local cZ = bot:GetNearbyTrees(280)
		if
			cZ ~= nil
			and #cZ >= 8
			and IsLocationVisible(GetTreeLocation(cZ[1]))
			and IsLocationPassable(GetTreeLocation(cZ[1]))
		then
			hEffectTarget = cZ[1]
			bw = "吃先知的树"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if DotaTime() < 0 and not ba then
		for loopVar6, loopVar7 in pairs(GetTeamPlayers(GetOpposingTeam())) do
			if GetSelectedHeroName(loopVar7) == "npc_dota_hero_monkey_king" then
				ba = true
			end
		end
	end
	if ba then
		local c_ = nil
		for aX, aY in pairs(bc) do
			if aY:IsAlive() and aY:GetUnitName() == "npc_dota_hero_monkey_king" then
				c_ = aY
				break
			end
		end
		if c_ ~= nil and mod.IsInRange(bot, c_, bv) then
			local d0 = bot:GetNearbyTrees(bv)
			for aX, d1 in pairs(d0) do
				local d2 = GetTreeLocation(d1)
				if GetUnitToLocationDistance(c_, d2) < 30 then
					bw = "砍大圣的树"
					return BOT_ACTION_DESIRE_HIGH, d1, bq, bw
				end
			end
		end
	end
	if DotaTime() > cY + 0.8 and (mod.IsGoingOnSomeone(bot) or mod.IsFarming(bot) or mod.IsRetreating(bot)) then
		cY = DotaTime()
		local d3 = 350
		local d0 = bot:GetNearbyTrees(d3)
		local d4 = #d0
		if d4 >= 1 then
			for d5 = 1, d4 do
				local d1 = d0[d5]
				if bot:IsFacingLocation(GetTreeLocation(d1), 7) then
					bw = "开视野"
					return BOT_ACTION_DESIRE_HIGH, d1, bq, bw
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_refresher"] = function(bm)
	local bv = 1000
	local bq = "none"
	local hEffectTarget = nil
	local bw = "刷新技能"
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if loadedScript ~= nil and loadedScript.CanUseRefresherShard ~= nil and loadedScript.CanUseRefresherShard() then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if #bx > 0 and (mod.IsGoingOnSomeone(bot) or mod.IsInTeamFight(bot)) and mod.CanUseRefresherShard(bot) then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_refresher_shard"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_refresher"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_ultimate_scepter_roshan"] = function(bm)
	local bv = 300
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bm:IsFullyCastable() then
		hEffectTarget = bot
		bw = "吃A杖"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_aghanims_shard_roshan"] = function(bm)
	local bv = 300
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bm:IsFullyCastable() then
		hEffectTarget = bot
		bw = "吃魔晶"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_rod_of_atos"] = function(bm)
	local bv = 1100 + b8
	local bq = "unit"
	if bm:GetName() == "item_gungir" then
		bq = "ground"
	end
	local hEffectTarget = nil
	local bw = nil
	local d6 = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	for aX, br in pairs(d6) do
		if
			mod.IsValid(br)
			and br:IsChanneling()
			and br:HasModifier("modifier_teleporting")
			and mod.CanCastOnNonMagicImmune(br)
			and mod.CanCastOnTargetAdvanced(br)
		then
			hEffectTarget = br
			bw = "打断:" .. mod.Chat.GetNormName(hEffectTarget)
			if bm:GetName() == "item_gungir" then
				hEffectTarget = hEffectTarget:GetLocation()
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if
		bf == BOT_MODE_RETREAT
		and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_MODERATE
		and mod.IsValid(d6[1])
		and mod.CanCastOnNonMagicImmune(d6[1])
		and mod.CanCastOnTargetAdvanced(d6[1])
		and not mod.IsDisabled(d6[1])
	then
		hEffectTarget = d6[1]
		bw = "撤退了"
		if bm:GetName() == "item_gungir" then
			hEffectTarget = hEffectTarget:GetLocation()
		end
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and not mod.IsDisabled(be)
			and mod.CanCastOnNonMagicImmune(be)
			and mod.CanCastOnTargetAdvanced(be)
			and GetUnitToUnitDistance(be, bot) <= bv
			and mod.IsMoving(be)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			if bm:GetName() == "item_gungir" then
				hEffectTarget = hEffectTarget:GetLocation()
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_satanic"] = function(bm)
	local bv = bot:GetAttackRange() + 250
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		bot:OriginalGetHealth() / bot:OriginalGetMaxHealth() < 0.62
		and #bx > 0
		and (mod.IsValidHero(be) and mod.IsInRange(bot, be, bv) or mod.IsValidHero(bx[1]) and mod.IsInRange(bot, bx[1], bv))
	then
		hEffectTarget = be
		bw = "进攻"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_shadow_amulet"] = function(bm)
	local bv = 600 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		not bot:HasModifier("modifier_invisible")
		and not bot:HasModifier("modifier_item_glimmer_cape")
		and not bot:HasModifier("modifier_item_shadow_amulet_fade")
		and not bot:HasModifier("modifier_slardar_amplify_damage")
		and not bot:HasModifier("modifier_item_dustofappearance")
	then
		local d7 = mod.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE)
		for aX, aY in pairs(d7) do
			if aY:IsAlive() and (aY:GetAttackTarget() == bot or aY:IsFacingLocation(bot:GetLocation(), 16)) then
				local bY = bot:GetNearbyTowers(888, true)
				if #bY == 0 and b9 < DotaTime() - 1.28 and not mod.IsGoingOnSomeone(bot) then
					b9 = DotaTime()
					hEffectTarget = bot
					bw = "自己用"
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
		if bot:IsRooted() or mod.IsStunProjectileIncoming(bot, 1000) then
			local bY = bot:GetNearbyTowers(888, true)
			if #bY == 0 and b9 < DotaTime() - 1.28 then
				b9 = DotaTime()
				hEffectTarget = bot
				bw = "撤退了"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	local cz = mod.GetNearbyHeroes(bot, 849, false, BOT_MODE_NONE)
	for aX, bA in pairs(cz) do
		if
			mod.IsValid(bA)
			and bA ~= bot
			and not bA:IsIllusion()
			and not bA:IsMagicImmune()
			and not bA:IsInvisible()
			and not bA:HasModifier("modifier_invisible")
			and not bA:HasModifier("modifier_item_glimmer_cape")
			and not bA:HasModifier("modifier_item_shadow_amulet_fade")
			and not bA:HasModifier("modifier_slardar_amplify_damage")
			and not bA:HasModifier("modifier_item_dustofappearance")
			and (bA:IsStunned() or bA:IsRooted() or mod.IsStunProjectileIncoming(bA, 1000))
		then
			local cl = bA:GetNearbyTowers(888, true)
			if #cl == 0 then
				hEffectTarget = bA
				bw = "帮助队友隐身"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_sheepstick"] = function(bm)
	local bv = 700 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	for aX, br in pairs(bx) do
		if mod.IsValid(br) and mod.CanCastOnNonMagicImmune(br) and abilityItemUsage.IsWithoutSpellShield(br) then
			if br:IsChanneling() or br:IsCastingAbility() then
				hEffectTarget = br
				bw = "打断:" .. mod.Chat.GetNormName(hEffectTarget)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if mod.IsRetreating(bot) then
				if not mod.IsDisabled(br) and not br:IsDisarmed() then
					hEffectTarget = br
					bw = "撤退:" .. mod.Chat.GetNormName(hEffectTarget)
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.IsInRange(bot, be, bv)
			and not mod.IsDisabled(be)
			and mod.CanCastOnNonMagicImmune(be)
			and abilityItemUsage.IsWithoutSpellShield(be)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_shivas_guard"] = function(bm)
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv + 50, true, BOT_MODE_NONE)
	local co = bot:GetNearbyCreeps(bv, true)
	if #co >= 6 or #bx >= 1 then
		hEffectTarget = bot
		bw = "启动希瓦"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_silver_edge"] = function(bm)
	local bv = 1600
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		mod.IsGoingOnSomeone(bot)
		and not bot:HasModifier("modifier_slardar_amplify_damage")
		and not bot:HasModifier("modifier_item_dustofappearance")
		and #bd == 0
	then
		if mod.IsValidHero(be) and mod.IsInRange(bot, be, 2400) and mod.CanCastOnMagicImmune(be) then
			local d8 = be:GetNearbyTowers(888, false)
			if #d8 == 0 then
				hEffectTarget = be
				bw = "破坏被动:" .. mod.Chat.GetNormName(be)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return abilityItemUsage.ConsiderItemDesire["item_invis_sword"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_solar_crest"] = function(bm)
	local bv = 1000
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bU = mod.GetAlliesNearLoc(bot:GetLocation(), 1000)
	for aX, bA in pairs(bU) do
		if
			mod.IsValidHero(bA)
			and mod.IsInRange(bot, bA, bv)
			and not bA:HasModifier("modifier_legion_commander_press_the_attack")
			and not bA:IsMagicImmune()
			and not bA:IsInvulnerable()
			and bA:CanBeSeen()
		then
			if not bA:IsBot() and bA:GetAttackTarget() ~= nil and bA:GetMaxHealth() - bA:GetHealth() >= 120 then
				hEffectTarget = bA
				bw = "Solar Crest"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if mod.IsGoingOnSomeone(bA) then
				local d9 = mod.GetProperTarget(bA)
				if
					mod.IsValidHero(d9)
					and bA:IsFacingLocation(d9:GetLocation(), 20)
					and mod.IsInRange(bA, d9, bA:GetAttackRange() + 100)
				then
					hEffectTarget = bA
					bw = "Solar Crest"
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_sphere"] = function(bm)
	local bv = 700 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local cz = mod.GetNearbyHeroes(bot, bv, false, BOT_MODE_NONE)
	for aX, bA in pairs(cz) do
		if
			mod.IsValidHero(bA)
			and bA ~= bot
			and not bA:IsMagicImmune()
			and not bA:IsInvulnerable()
			and not bA:IsIllusion()
			and not bA:HasModifier("modifier_item_sphere_target")
			and not bA:HasModifier("modifier_antimage_spell_shield")
			and (
				mod.IsUnitTargetProjectileIncoming(bA, 800)
				or mod.IsWillBeCastUnitTargetSpell(bA, 1200)
				or bot:GetHealth() < 150
			)
		then
			hEffectTarget = bA
			bw = "帮助队友"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.IsValidHero(be) and mod.IsInRange(bot, be, 2400) and not mod.IsInRange(bot, be, 800) then
		if #cz >= 2 then
			local cJ = nil
			local da = 9999
			for aX, bA in pairs(cz) do
				if
					bA ~= bot
					and not bA:IsIllusion()
					and mod.IsInRange(bA, be, da)
					and not bA:HasModifier("modifier_item_sphere_target")
					and not bA:HasModifier("modifier_antimage_spell_shield")
				then
					cJ = bA
					da = GetUnitToUnitDistance(be, bA)
					if mod.IsHumanPlayer(bA) then
						break
					end
				end
			end
			if cJ ~= nil then
				hEffectTarget = cJ
				bw = "先给前排套上"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_spirit_vessel"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_urn_of_shadows"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_essence_distiller"] = function(bm)
	if bm:GetCurrentCharges() == 0 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 950 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and (
				mod.CanCastOnNonMagicImmune(be)
					and mod.IsInRange(bot, be, bv)
					and not be:HasModifier("modifier_item_urn_damage")
					and not be:HasModifier("modifier_item_spirit_vessel_damage")
					and not be:HasModifier("modifier_item_essence_distiller_damage")
					and not be:HasModifier("modifier_arc_warden_tempest_double")
					and (mod.GetHP(be) < 0.95 or mod.IsInRange(bot, be, 700))
				or be:HasModifier("modifier_invoker_cold_snap_freeze")
			)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if bot:GetActiveMode() ~= BOT_MODE_ROSHAN then
		local bU = mod.GetNearbyHeroes(bot, bv + 80, false, BOT_MODE_NONE)
		local c0 = nil
		local c1 = 99999
		for aX, bA in pairs(bU) do
			if
				mod.IsValid(bA)
				and not bA:IsIllusion()
				and bA:DistanceFromFountain() > 800
				and mod.CanCastOnNonMagicImmune(bA)
				and not bA:WasRecentlyDamagedByAnyHero(3.1)
				and not bA:HasModifier("modifier_item_spirit_vessel_heal")
				and not bA:HasModifier("modifier_item_urn_heal")
				and not bA:HasModifier("modifier_item_essence_distiller_heal")
				and not bA:HasModifier("modifier_fountain_aura")
				and not bA:HasModifier("modifier_arc_warden_tempest_double")
				and bA:OriginalGetMaxHealth() - bA:OriginalGetHealth() > 450
				and #bc == 0
			then
				if bA:OriginalGetHealth() < c1 then
					c0 = bA
					c1 = bA:OriginalGetHealth()
				end
			end
		end
		if c0 ~= nil then
			hEffectTarget = c0
			bw = "治疗:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_tango"] = function(bm)
	if bot:DistanceFromFountain() < 3300 or bot:HasModifier("modifier_tango_heal") then
		return BOT_ACTION_DESIRE_NONE
	end
	if bot._lastTangoUseTime and DotaTime() - bot._lastTangoUseTime < 16 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 300 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local db = bm:GetCurrentCharges()
	if
		bot:GetLevel() <= 12
		and (#bc == 0 or bf == BOT_MODE_LANING)
		and db >= 1
		and DotaTime() > 10
		and DotaTime() > mod.Role["fLastGiveTangoTime"] + 40.0
	then
		local bU = mod.GetNearbyHeroes(bot, 800, false, BOT_MODE_NONE)
		for aX, bA in pairs(bU) do
			if bA ~= bot then
				local dc = bA:FindItemSlot("item_tango")
				if
					dc == -1
					and not bA:IsIllusion()
					and bA:OriginalGetMaxHealth() - bA:OriginalGetHealth() > 200
					and not bA:HasModifier("modifier_tango_heal")
					and not bA:HasModifier("modifier_arc_warden_tempest_double")
					and not mod.IsMeepoClone(bot)
					and not mod.IsMeepoClone(bA)
					and mod.Item.GetItemCount(bA, "item_tango_single") == 0
					and mod.Item.GetEmptyInventoryAmount(bA) >= 4
				then
					mod.Role["fLastGiveTangoTime"] = DotaTime()
					hEffectTarget = bA
					bw = "分享队友吃树"
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
	end
	local dd = mod.IsItemAvailable("item_tango_single")
	if dd ~= nil and dd:IsFullyCastable() then
		return 0
	end
	return abilityItemUsage.ConsiderItemDesire["item_tango_single"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_tango_single"] = function(bm)
	if bot:DistanceFromFountain() < 3300 or bot:HasModifier("modifier_tango_heal") then
		return 0
	end
	if bot._lastTangoUseTime and DotaTime() - bot._lastTangoUseTime < 16 then
		return 0
	end
	local bv = 300 + b8
	local bq = "tree"
	local hEffectTarget = nil
	local bw = nil
	local de = bm:GetName() == "item_tango" and 200 or 160
	local bQ = bot:OriginalGetMaxHealth() - bot:OriginalGetHealth()
	if bot:HasModifier("modifier_furion_sprout_damage") then
		local cZ = bot:GetNearbyTrees(280)
		if
			cZ ~= nil
			and #cZ >= 8
			and IsLocationVisible(GetTreeLocation(cZ[1]))
			and IsLocationPassable(GetTreeLocation(cZ[1]))
		then
			hEffectTarget = cZ[1]
			bw = "吃先知的树"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if not bot:HasModifier("modifier_flask_healing") and not bot:HasModifier("modifier_juggernaut_healing_ward_heal") then
		local df = bot:GetNearbyTrees(800)
		local dg = df[1]
		local dh = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
		local di = dh[1]
		local dj = bot:GetNearbyTowers(1400, true)
		local dk = dj[1]
		local cA = mod.GetHP(bot)
		local dl = #dh == 0 or di ~= nil and not mod.IsInRange(bot, di, 400)
		if dg ~= nil and bQ >= 350 and dl then
			local dm = GetTreeLocation(dg)
			if
				IsLocationVisible(dm)
				and IsLocationPassable(dm)
				and (#dj == 0 or GetUnitToLocationDistance(dk, dm) > 920)
			then
				hEffectTarget = dg
				bw = "proactive heal"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
		if dg ~= nil then
			local dm = GetTreeLocation(dg)
			if
				bQ > de
				and IsLocationVisible(dm)
				and IsLocationPassable(dm)
				and (#dh == 0 or not mod.IsInRange(bot, di, 800))
				and (#dh == 0 or GetUnitToLocationDistance(bot, dm) * 1.6 < GetUnitToUnitDistance(bot, di))
				and (#dj == 0 or GetUnitToLocationDistance(dk, dm) > 920)
			then
				hEffectTarget = dg
				bw = "800码内的树"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
		local dn = bot:GetNearbyTowers(1100, false)
		if #dn >= 1 and bQ > de + 20 then
			local dp = dn[1]
			if dp ~= nil then
				local dq = 1100 - GetUnitToUnitDistance(bot, dp)
				local dr = bot:GetNearbyTrees(dq)
				local dg = dr[1]
				if dg ~= nil then
					local dm = GetTreeLocation(dg)
					if IsLocationVisible(dm) and IsLocationPassable(dm) then
						hEffectTarget = dg
						bw = "吃塔下的树"
						return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
					end
				end
			end
		end
		local cZ = bot:GetNearbyTrees(280)
		if
			cZ[1] ~= nil
			and IsLocationVisible(GetTreeLocation(cZ[1]))
			and IsLocationPassable(GetTreeLocation(cZ[1]))
		then
			if bQ > de then
				hEffectTarget = cZ[1]
				bw = "近处的树"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if bQ > de * 0.38 and bot:WasRecentlyDamagedByAnyHero(2.0) then
				hEffectTarget = cZ[1]
				bw = "提前吃树"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if
		DotaTime() > 4 * 60 + 30
		and be == nil
		and bm:GetName() == "item_tango_single"
		and bot:DistanceFromFountain() > 3000
		and bf ~= BOT_MODE_RUNE
	then
		local ds = mod.Item.GetItemCount(bot, "item_tango_single")
		local bc = mod.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE)
		if ds >= 2 then
			local df = bot:GetNearbyTrees(1200)
			if
				df[1] ~= nil
				and IsLocationVisible(GetTreeLocation(df[1]))
				and IsLocationPassable(GetTreeLocation(df[1]))
				and #bc == 0
			then
				hEffectTarget = df[1]
				bw = "消耗共享吃树"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
		if DotaTime() > 7 * 60 + 30 then
			local df = bot:GetNearbyTrees(1200)
			if
				df[1] ~= nil
				and IsLocationVisible(GetTreeLocation(df[1]))
				and IsLocationPassable(GetTreeLocation(df[1]))
				and bQ > 60
				and #bc == 0
			then
				hEffectTarget = df[1]
				bw = "用掉共享吃树"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_tome_of_knowledge"] = function(bm)
	local bv = 300
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if bm:IsFullyCastable() then
		hEffectTarget = bot
		bw = "读书"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
function abilityItemUsage.GetLaningTPLocation(val39, dt, botLocation)
	if GetGameMode() == GAMEMODE_1V1MID or GetGameMode() == GAMEMODE_MO then
		return nil, false
	end
	local du
	local dv = false
	if IsLanMode and IsLanMode() then
		local val40 = val39:GetAssignedLane()
		if val40 == LANE_TOP or val40 == LANE_MID or val40 == LANE_BOT then
			du = val40
		end
	end
	if du == nil then
		local val41 = mod.GetPosition(val39)
		if team == TEAM_RADIANT then
			if val41 == 1 then
				du = LANE_BOT
			elseif val41 == 2 then
				du = LANE_MID
			elseif val41 == 3 or val41 == 4 then
				du = LANE_TOP
			elseif val41 == 5 then
				du = LANE_BOT
			end
		elseif team == TEAM_DIRE then
			if val41 == 1 then
				du = LANE_TOP
			elseif val41 == 2 then
				du = LANE_MID
			elseif val41 == 3 or val41 == 4 then
				du = LANE_BOT
			elseif val41 == 5 then
				du = LANE_TOP
			end
		end
	end
	local dw = GetAmountAlongLane(du, botLocation)
	local dx = GetLaneFrontAmount(team, du, false)
	if dw.distance > dt or dw.amount < dx / 5 then
		dv = true
	end
	local dy = { [LANE_TOP] = "top", [LANE_MID] = "mid", [LANE_BOT] = "bot" }
	if dv then
		log(
			"[TP-DIAG laning] %s pos=%s assigned=%s chose=%s lan=%s",
			val39:GetUnitName(),
			tostring(mod.GetPosition(val39)),
			tostring(dy[val39:GetAssignedLane()] or val39:GetAssignedLane()),
			tostring(dy[du] or du),
			tostring(IsLanMode and IsLanMode())
		)
	end
	return GetLaneFrontLocation(team, du, 100), dv
end
function abilityItemUsage.GetDefendTPLocation(dz)
	return GetLaneFrontLocation(team, dz, -950)
end
function abilityItemUsage.GetPushTPLocation(dz)
	local dx = GetLaneFrontLocation(team, dz, 0)
	local dA = mod.GetNearbyLocationToTp(dx)
	if mod.GetLocationToLocationDistance(dx, dA) < 2000 then
		return dA
	end
end
function abilityItemUsage.CanJuke()
	local dB = bot:GetNearbyTowers(350, false)
	if
		dB[1] ~= nil
		and dB[1]:DistanceFromFountain() > bot:DistanceFromFountain() + 100
		and mod.GetEnemyCount(bot, 700) == 0
	then
		return true
	end
	if
		mod.GetModifierTime(bot, "modifier_dazzle_shallow_grave") > 3.0
		or mod.GetModifierTime(bot, "modifier_oracle_false_promise_timer") > 3.0
	then
		return true
	end
	local dC = GetTeamPlayers(GetOpposingTeam())
	local dD = GetHeightLevel(bot:GetLocation())
	for i9 = 1, #dC do
		local val42 = GetHeroLastSeenInfo(dC[i9])
		if val42 ~= nil then
			local val43 = val42[1]
			if val43 ~= nil and val43.time_since_seen < 2.0 then
				if GetUnitToLocationDistance(bot, val43.location) < 1300 and GetHeightLevel(val43.location) < dD then
					return false
				end
				if GetUnitToLocationDistance(bot, val43.location) < 600 then
					local bc = mod.GetNearbyHeroes(bot, 600, true, BOT_MODE_NONE)
					if #bc == 0 then
						return false
					end
				end
			end
		end
	end
	local dE = 0
	local dF = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	for aX, aY in pairs(dF) do
		local dG = aY:GetEstimatedDamageToTarget(true, bot, 4.0, DAMAGE_TYPE_ALL)
		dE = dE + dG
		if bot:OriginalGetHealth() <= dE then
			return false
		end
	end
	return true
end
function abilityItemUsage.GetNumHeroWithinRange(dH)
	local dC = GetTeamPlayers(GetOpposingTeam())
	local dI = 0
	for i10 = 1, #dC do
		local val44 = GetHeroLastSeenInfo(dC[i10])
		if val44 ~= nil then
			local val45 = val44[1]
			if val45 ~= nil and val45.time_since_seen < 2.0 and GetUnitToLocationDistance(bot, val45.location) < dH then
				dI = dI + 1
			end
		end
	end
	return dI
end
function abilityItemUsage.IsFarmingAlways(val46)
	local dJ = val46:GetAttackTarget()
	if
		mod.IsValid(dJ)
		and dJ:GetTeam() == TEAM_NEUTRAL
		and not mod.IsRoshan(dJ)
		and not mod.IsKeyWordUnit("warlock", dJ)
		and abilityItemUsage.GetNumEnemyNearby(GetAncient(team)) >= 2
	then
		return true
	end
	local cz = mod.GetNearbyHeroes(val46, 800, false, BOT_MODE_NONE)
	if
		mod.IsValid(dJ)
		and dJ:IsAncientCreep()
		and not mod.IsRoshan(dJ)
		and not mod.IsKeyWordUnit("warlock", dJ)
		and val46:GetPrimaryAttribute() == ATTRIBUTE_INTELLECT
		and unitName ~= "npc_dota_hero_ogre_magi"
		and #cz < 2
	then
		return true
	end
	if abilityItemUsage.GetNumEnemyNearby(GetAncient(team)) >= 4 and val46:DistanceFromFountain() >= 4800 and #cz < 2 then
		return true
	end
	return false
end
function abilityItemUsage.IsBaseTowerDestroyed()
	for i11 = 9, 10, 1 do
		local aU = GetTower(team, i11)
		if aU == nil or aU:GetHealth() / aU:GetMaxHealth() < 0.99 then
			return true
		end
	end
	return false
end
if bot.useProphetTP == nil then
	bot.useProphetTP = false
end
if bot.ProphetTPLocation == nil then
	bot.ProphetTPLocation = bot:GetLocation()
end
abilityItemUsage.ConsiderItemDesire["item_tpscroll"] = function(bm)
	if
		bf == BOT_MODE_RUNE
		or bot:IsRooted()
		or bot:HasModifier("modifier_item_armlet_unholy_strength")
		or bot:HasModifier("modifier_kunkka_x_marks_the_spot")
		or bot:HasModifier("modifier_teleporting")
		or bot:HasModifier("modifier_sniper_assassinate")
		or bot:HasModifier("modifier_viper_nethertoxin")
		or bot:HasModifier("modifier_oracle_false_promise_timer") and mod.GetModifierTime(
			bot,
			"modifier_oracle_false_promise_timer"
		) <= 3.2
		or bot:HasModifier("modifier_jakiro_macropyre_burn") and mod.GetModifierTime(bot, "modifier_jakiro_macropyre_burn") >= 1.4
		or bot:HasModifier("modifier_arc_warden_tempest_double") and bot:GetRemainingLifespan() < 3.3
		or mod.IsDoingRoshan(bot) and GetUnitToLocationDistance(bot, mod.GetCurrentRoshanLocation()) <= 2800
		or bot._roshDipActive and bot:IsAlive() and GetUnitToLocationDistance(bot, mod.GetCurrentRoshanLocation()) <= 3000
		or mod.IsDoingTormentor(bot) and GetUnitToLocationDistance(bot, mod.GetTormentorLocation(GetTeam())) <= 2800
	then
		return BOT_ACTION_DESIRE_NONE
	end
	if bot:GetHealth() < 240 then
		local dK = mod.GetAttackProjectileDamageByRange(bot, 1600) * 2
		if bot:GetHealth() < bot:GetActualIncomingDamage(dK, DAMAGE_TYPE_PHYSICAL) then
			return BOT_ACTION_DESIRE_NONE
		end
	end
	if bot:HasModifier("modifier_spirit_breaker_charge_of_darkness") or bot.healInBase then
		return BOT_ACTION_DESIRE_NONE
	end
	local bY = bot:GetNearbyTowers(888, true)
	if #bY > 0 then
		return BOT_ACTION_DESIRE_NONE
	end
	local dL = nil
	local bq = "ground"
	local hEffectTarget = nil
	local bw = nil
	local dt = 5500
	local bf = bot:GetActiveMode()
	local dM = bot:GetActiveModeDesire()
	local botLocation = bot:GetLocation()
	local bR = mod.GetHP(bot)
	local bT = mod.GetMP(bot)
	local ax = abilityItemUsage.GetNumHeroWithinRange(1600)
	local ay = mod.GetAllyCount(bot, 1600)
	local dN = mod.IsItemAvailable("item_flask")
	if bot:GetLevel() > 12 and bot:DistanceFromFountain() < 600 then
		dt = dt + 600
	end
	if
		bot:DistanceFromFountain() < 1500
		and bR > 0.75
		and ax == 0
		and not bot:HasModifier("modifier_teleporting")
		and DotaTime() > 15
	then
		local dO = abilityItemUsage.GetLaneByPosition(bot)
		if not mod.IsInLaningPhase() and DotaTime() > 10 * 60 then
			if bf == BOT_MODE_DEFEND_TOWER_TOP then
				dO = LANE_TOP
			elseif bf == BOT_MODE_DEFEND_TOWER_MID then
				dO = LANE_MID
			elseif bf == BOT_MODE_DEFEND_TOWER_BOT then
				dO = LANE_BOT
			elseif bf == BOT_MODE_PUSH_TOWER_TOP then
				dO = LANE_TOP
			elseif bf == BOT_MODE_PUSH_TOWER_MID then
				dO = LANE_MID
			elseif bf == BOT_MODE_PUSH_TOWER_BOT then
				dO = LANE_BOT
			elseif bot.laneToDefend ~= nil then
				dO = bot.laneToDefend
			else
				local dP = 0
				for aX, dQ in pairs({ LANE_TOP, LANE_MID, LANE_BOT }) do
					local dx = GetLaneFrontLocation(GetOpposingTeam(), dQ, 0)
					local dR = mod.GetLastSeenEnemiesNearLoc(dx, 800)
					if #dR > dP then
						dP = #dR
						dO = dQ
					end
				end
			end
		end
		local dS = GetLaneFrontLocation(GetTeam(), dO, -500)
		local dT = { [LANE_TOP] = "top", [LANE_MID] = "mid", [LANE_BOT] = "bot" }
		log(
			"[TP-DIAG fountain] %s pos=%s assigned=%s chose=%s mode=%s lan=%s",
			unitName,
			tostring(mod.GetPosition(bot)),
			tostring(dT[bot:GetAssignedLane()] or bot:GetAssignedLane()),
			tostring(dT[dO] or dO),
			tostring(bf),
			tostring(IsLanMode and IsLanMode())
		)
		if dS ~= nil and GetUnitToLocationDistance(bot, dS) > 3500 then
			local dU = { [LANE_TOP] = "top", [LANE_MID] = "mid", [LANE_BOT] = "bot" }
			local dV = mod.GetLastSeenEnemiesNearLoc(dS, 1600)
			local dW = mod.GetAlliesNearLoc(dS, 1600)
			if #dV <= 1 or #dW >= #dV then
				return BOT_ACTION_DESIRE_HIGH, dS, bq, "fountain TP out"
			end
			local dX = GetLaneFrontLocation(GetTeam(), dO, -1500)
			if GetUnitToLocationDistance(bot, dX) > 3500 then
				return BOT_ACTION_DESIRE_HIGH, dX, bq, "fountain TP safe"
			end
		end
	end
	if bf == BOT_MODE_LANING then
		hEffectTarget, shouldTp = abilityItemUsage.GetLaningTPLocation(bot, dt, botLocation)
		bw = "出去发育"
		if shouldTp then
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if
		abilityItemUsage.IsInvFull(bot)
		and abilityItemUsage.GetNumStashItem(bot) >= 1
		and (bot:GetStashValue() >= 1200 and abilityItemUsage.IsThereRecipeInStash(bot) or bot:GetStashValue() >= 2000 and bot:GetGold() > 1100)
		and not mod.IsPushing(bot)
		and bot:GetActiveMode() ~= BOT_MODE_ATTACK
		and not mod.IsInTeamFight(bot, 1200)
		and not mod.Utils.IsTeamPushingSecondTierOrHighGround(bot)
		and ax == 0
	then
		hEffectTarget = mod.GetTeamFountain()
		bw = "撤退:1"
		if unitName == "npc_dota_hero_furion" then
			local dY = bot:GetAbilityByName("furion_teleportation")
			if dY:IsTrained() and dY:IsFullyCastable() then
				bot.useProphetTP = true
				bot.ProphetTPLocation = hEffectTarget
				return BOT_ACTION_DESIRE_NONE
			end
		end
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if mod.IsDoingRoshan(bot) and ax == 0 and not mod.IsRoshanCloseToChangingSides() then
		local dZ = mod.GetCurrentRoshanLocation()
		local d_ = mod.GetNearbyLocationToTp(dZ)
		local e0 = GetUnitToLocationDistance(bot, d_)
		local e1 = GetUnitToLocationDistance(bot, dZ)
		if e0 > 8000 and e1 > 8000 and e1 > e0 then
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = d_
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, d_, "ground", "tp_roshan"
		end
	end
	if
		(bot:GetActiveMode() == BOT_MODE_SIDE_SHOP or bot:GetActiveMode() == BOT_MODE_WATCHER)
		and ax == 0
		and (not mod.IsInTeamFight(bot, 1200) or not mod.IsGoingOnSomeone(bot) or not mod.IsDefending(bot))
	then
		local e2 = mod.GetTormentorLocation(team)
		if GetUnitToLocationDistance(bot, e2) > 8000 then
			hEffectTarget = mod.GetNearbyLocationToTp(e2)
			bw = "tormentor"
			if mod.GetLocationToLocationDistance(bot:GetLocation(), hEffectTarget) > 4400 then
				if unitName == "npc_dota_hero_furion" then
					local dY = bot:GetAbilityByName("furion_teleportation")
					if dY:IsTrained() and dY:IsFullyCastable() then
						bot.useProphetTP = true
						bot.ProphetTPLocation = hEffectTarget
						return BOT_ACTION_DESIRE_NONE
					end
				end
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if mod.IsDefending(bot) and dM > BOT_MODE_DESIRE_LOW and ax == 0 then
		local e3, e4 = LANE_MID, "tower_mid"
		if bf == BOT_MODE_DEFEND_TOWER_TOP then
			e3, e4 = LANE_TOP, "tower_top"
		end
		if bf == BOT_MODE_DEFEND_TOWER_BOT then
			e3, e4 = LANE_BOT, "tower_bot"
		end
		local dw = GetAmountAlongLane(e3, botLocation)
		local dx = GetLaneFrontAmount(team, e3, false)
		if dw.distance > dt or dw.amount < dx / 5 then
			dL = abilityItemUsage.GetDefendTPLocation(e3)
		end
		if dL ~= nil and GetUnitToLocationDistance(bot, dL) > dt - 500 then
			hEffectTarget = dL
			bw = "前往守塔:" .. e4
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_ABSOLUTE, hEffectTarget, bq, bw
		end
	end
	if mod.IsPushing(bot) and dM >= BOT_MODE_DESIRE_LOW and ax == 0 then
		local e5, e4 = LANE_MID, "tower_mid"
		if bf == BOT_MODE_PUSH_TOWER_TOP then
			e5, e4 = LANE_TOP, "tower_top"
		end
		if bf == BOT_MODE_PUSH_TOWER_BOT then
			e5, e4 = LANE_BOT, "tower_bot"
		end
		local dw = GetAmountAlongLane(e5, botLocation)
		local dx = GetLaneFrontAmount(team, e5, false)
		if dw.amount < dx - 0.05 and (dw.distance > dt or dw.amount < dx / 5) then
			dL = abilityItemUsage.GetPushTPLocation(e5)
		end
		if
			dL ~= nil
			and GetUnitToLocationDistance(bot, dL) > dt - 600
			and GetAmountAlongLane(e5, dL).amount > dw.amount
		then
			hEffectTarget = dL
			bw = "前往推塔:" .. e4
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if bf == BOT_MODE_DEFEND_ALLY and dM >= BOT_MODE_DESIRE_LOW and mod.Role.CanBeSupport(unitName) and ax == 0 then
		local ap = bot:GetTarget()
		if ap ~= nil and ap:IsHero() and GetUnitToUnitDistance(bot, ap) > dt then
			local dA = mod.GetNearbyLocationToTp(ap:GetLocation())
			if dA ~= nil and GetUnitToLocationDistance(bot, dA) > dt - 800 then
				dL = dA
			end
		end
		if dL ~= nil then
			hEffectTarget = dL
			bw = "支援队友:" .. mod.Chat.GetNormName(ap)
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if
		bf == BOT_MODE_RETREAT
		and dM >= BOT_MODE_DESIRE_LOW
		and bot:GetLevel() >= 3
		and not bot:HasModifier("modifier_arc_warden_tempest_double")
	then
		if
			bR < 0.19
			and (bot:WasRecentlyDamagedByAnyHero(8.0) or bR < 0.12)
			and unitName ~= "npc_dota_hero_huskar"
			and (unitName ~= "npc_dota_hero_slark" or bot:GetLevel() <= 5)
			and ax == 0
			and dN == nil
			and not bot:HasModifier("modifier_tango_heal")
			and not bot:HasModifier("modifier_flask_healing")
			and not bot:HasModifier("modifier_juggernaut_healing_ward_heal")
			and not bot:HasModifier("modifier_item_urn_heal")
			and not bot:HasModifier("modifier_item_spirit_vessel_heal")
			and bot:DistanceFromFountain() > dt
		then
			dL = mod.GetTeamFountain()
			bw = "撤退:1"
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, dL, bq, bw
		end
		local e6 = mod.GetNearbyHeroes(bot, 1500, false, BOT_MODE_ATTACK)
		if
			bR < 0.15 + 0.24 * ax
			and #e6 == 0
			and bot:WasRecentlyDamagedByAnyHero(6.0)
			and abilityItemUsage.CanJuke()
			and ax <= (bR < 0.4 and 2 or 3)
			and ay <= 2
			and dN == nil
			and not bot:HasModifier("modifier_tango_heal")
			and not bot:HasModifier("modifier_flask_healing")
			and not bot:HasModifier("modifier_item_urn_heal")
			and not bot:HasModifier("modifier_item_spirit_vessel_heal")
			and not bot:HasModifier("modifier_juggernaut_healing_ward_heal")
			and bot:DistanceFromFountain() > dt - 600
		then
			dL = mod.GetTeamFountain()
			bw = "撤退:2"
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, dL, bq, bw
		end
		if
			(bR < 0.34 or bR + bT < 0.43)
			and #e6 == 0
			and bot:GetLevel() >= 9
			and abilityItemUsage.CanJuke()
			and ax <= 1
			and ay <= 2
			and dN == nil
			and bot:GetAttackTarget() == nil
			and unitName ~= "npc_dota_hero_huskar"
			and unitName ~= "npc_dota_hero_slark"
			and not bot:HasModifier("modifier_flask_healing")
			and not bot:HasModifier("modifier_clarity_potion")
			and not bot:HasModifier("modifier_filler_heal")
			and not bot:HasModifier("modifier_item_urn_heal")
			and not bot:HasModifier("modifier_item_spirit_vessel_heal")
			and not bot:HasModifier("modifier_juggernaut_healing_ward_heal")
			and not bot:HasModifier("modifier_bottle_regeneration")
			and not bot:HasModifier("modifier_tango_heal")
			and bot:DistanceFromFountain() > dt - 600
		then
			dL = mod.GetTeamFountain()
			bw = "撤退:3"
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, dL, bq, bw
		end
	end
	if
		bf == BOT_MODE_FARM
		and bot:DistanceFromFountain() < 800
		and not abilityItemUsage.IsBaseTowerDestroyed()
		and bR > 0.9
		and bT > 0.8
	then
		local e7, e8 = mod.GetMostFarmLaneDesire(bot)
		if e8 > 0.1 then
			farmTpLoc = GetLaneFrontLocation(team, e7, 0)
			local dA = mod.GetNearbyLocationToTp(farmTpLoc)
			if
				dA ~= nil
				and farmTpLoc ~= nil
				and mod.IsLocHaveTower(2000, false, farmTpLoc)
				and GetUnitToLocationDistance(bot, dA) > dt
			then
				dL = farmTpLoc
			end
		end
		if dL ~= nil then
			hEffectTarget = dL
			bw = "出去发育"
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_ABSOLUTE, hEffectTarget, bq, bw
		end
	end
	if
		bot:GetLevel() >= 10
		and bf ~= BOT_MODE_ROSHAN
		and not abilityItemUsage.IsBaseTowerDestroyed()
		and mod.GetAllyCount(bot, 1600) <= 2
		and mod.Role.ShouldTpToFarm()
		and not mod.Role.IsAllyHaveAegis()
		and not mod.Role.CanBeSupport(unitName)
		and not mod.IsEnemyHeroAroundLocation(GetAncient(team):GetLocation(), 3300)
	then
		local e6 = mod.GetNearbyHeroes(bot, 1600, false, BOT_MODE_ATTACK)
		local e9 = mod.GetNearbyHeroes(bot, 1400, true, BOT_MODE_NONE)
		local ea = bot:GetNearbyCreeps(1600, true)
		local e7, e8 = mod.GetMostFarmLaneDesire(bot)
		local eb = false
		if mod.IsItemAvailable("item_travel_boots") or mod.IsItemAvailable("item_travel_boots_2") then
			eb = true
		end
		if e8 > (eb and 0.7 or 0.8) and #e9 == 0 and #ea == 0 and #e6 == 0 then
			if eb then
				dL = GetLaneFrontLocation(team, e7, -600)
				local cz = mod.GetAlliesNearLoc(dL, 1600)
				if GetUnitToLocationDistance(bot, dL) > dt - 1500 and #cz == 0 then
					mod.Role["lastFarmTpTime"] = DotaTime()
					bw = "飞鞋带线"
					if unitName == "npc_dota_hero_furion" then
						local dY = bot:GetAbilityByName("furion_teleportation")
						if dY:IsTrained() and dY:IsFullyCastable() then
							bot.useProphetTP = true
							bot.ProphetTPLocation = dL
							return BOT_ACTION_DESIRE_NONE
						end
					end
					return BOT_ACTION_DESIRE_HIGH, dL, bq, bw
				end
			end
			dL = GetLaneFrontLocation(team, e7, 0)
			local dA = mod.GetNearbyLocationToTp(dL)
			local cz = mod.GetAlliesNearLoc(dL, 1600)
			if
				dA ~= nil
				and mod.IsLocHaveTower(1850, false, dL)
				and GetUnitToLocationDistance(bot, dA) > dt - 800
				and #cz == 0
			then
				mod.Role["lastFarmTpTime"] = DotaTime()
				bw = "线上打钱"
				if unitName == "npc_dota_hero_furion" then
					local dY = bot:GetAbilityByName("furion_teleportation")
					if dY:IsTrained() and dY:IsFullyCastable() then
						bot.useProphetTP = true
						bot.ProphetTPLocation = dA
						return BOT_ACTION_DESIRE_NONE
					end
				end
				return BOT_ACTION_DESIRE_HIGH, dA, bq, bw
			end
		end
	end
	if
		bot:GetLevel() > 10
		and bf ~= BOT_MODE_SECRET_SHOP
		and bf ~= BOT_MODE_ROSHAN
		and bf ~= BOT_MODE_ATTACK
		and (be == nil or not be:IsHero())
	then
		local e9 = mod.GetNearbyHeroes(bot, 1400, true, BOT_MODE_NONE)
		local aw = mod.GetTeamFightLocation(bot)
		local eb = false
		if mod.IsItemAvailable("item_travel_boots") or mod.IsItemAvailable("item_travel_boots_2") then
			eb = true
		end
		if unitName == "npc_dota_hero_spectre" then
			local ec = bot:GetAbilityByName("spectre_shadow_step")
			local ed = bot:GetAbilityByName("spectre_haunt")
			if ec:IsFullyCastable() or ed:IsTrained() and ed:IsFullyCastable() then
				return BOT_ACTION_DESIRE_NONE
			end
		end
		if #e9 == 0 and aw ~= nil and GetUnitToLocationDistance(bot, aw) > dt - 1200 then
			if eb then
				bw = "飞鞋支援团战距离:" .. GetUnitToLocationDistance(bot, aw)
				if unitName == "npc_dota_hero_furion" then
					local dY = bot:GetAbilityByName("furion_teleportation")
					if dY:IsTrained() and dY:IsFullyCastable() then
						bot.useProphetTP = true
						bot.ProphetTPLocation = aw
						return BOT_ACTION_DESIRE_NONE
					end
				end
				return BOT_ACTION_DESIRE_HIGH, aw, bq, bw
			end
			local dA = mod.GetNearbyLocationToTp(aw)
			if
				dA ~= nil
				and mod.GetLocationToLocationDistance(dA, aw) < 1800
				and GetUnitToLocationDistance(bot, dA) > dt - 1200
			then
				bw = "支援团战:" .. GetUnitToLocationDistance(bot, aw)
				if unitName == "npc_dota_hero_furion" then
					local dY = bot:GetAbilityByName("furion_teleportation")
					if dY:IsTrained() and dY:IsFullyCastable() then
						bot.useProphetTP = true
						bot.ProphetTPLocation = dA
						return BOT_ACTION_DESIRE_NONE
					end
				end
				return BOT_ACTION_DESIRE_HIGH, dA, bq, bw
			end
		end
		local ee = GetAncient(team)
		if
			bot:GetLevel() >= 15
			and #e9 == 0
			and mod.Role.ShouldTpToFarm()
			and bot:DistanceFromFountain() > 2000
			and GetUnitToUnitDistance(bot, ee) > dt - 200
			and mod.GetAroundTargetAllyHeroCount(ee, 1400) == 0
		then
			local ef = mod.GetNearestLaneFrontLocation(ee:GetLocation(), true, 400)
			if ef ~= nil and GetUnitToLocationDistance(ee, ef) <= 1600 then
				mod.Role["lastFarmTpTime"] = DotaTime()
				bw = "守护遗迹"
				if unitName == "npc_dota_hero_furion" then
					local dY = bot:GetAbilityByName("furion_teleportation")
					if dY:IsTrained() and dY:IsFullyCastable() then
						bot.useProphetTP = true
						bot.ProphetTPLocation = ee:GetLocation()
						return BOT_ACTION_DESIRE_NONE
					end
				end
				return BOT_ACTION_DESIRE_HIGH, ee:GetLocation(), bq, bw
			end
			local eg = GetTower(team, 9)
			local eh = GetTower(team, 10)
			if eg == nil and eh == nil then
				local b0 = GetUnitList(UNIT_LIST_ENEMY_CREEPS)
				for aX, b2 in pairs(b0) do
					if
						mod.IsValid(b2)
						and GetUnitToUnitDistance(ee, b2) <= 800
						and (b2:GetAttackTarget() == ee or bot:GetLevel() >= 15)
					then
						mod.Role["lastFarmTpTime"] = DotaTime()
						bw = "保护遗迹"
						if unitName == "npc_dota_hero_furion" then
							local dY = bot:GetAbilityByName("furion_teleportation")
							if dY:IsTrained() and dY:IsFullyCastable() then
								bot.useProphetTP = true
								bot.ProphetTPLocation = ee:GetLocation()
								return BOT_ACTION_DESIRE_NONE
							end
						end
						return BOT_ACTION_DESIRE_HIGH, ee:GetLocation(), bq, bw
					end
				end
			end
		end
	end
	if
		(bR + bT < 0.3 or bR < 0.2)
		and bot:GetLevel() >= 6
		and unitName ~= "npc_dota_hero_huskar"
		and unitName ~= "npc_dota_hero_slark"
		and not bot:HasModifier("modifier_arc_warden_tempest_double")
	then
		if
			abilityItemUsage.CanJuke()
			and bot:DistanceFromFountain() > dt + 200
			and ax <= 1
			and ay <= 1
			and mod.GetProperTarget(bot) == nil
			and dN == nil
			and bot:GetAttackTarget() == nil
			and not bot:HasModifier("modifier_flask_healing")
			and not bot:HasModifier("modifier_clarity_potion")
			and not bot:HasModifier("modifier_filler_heal")
			and not bot:HasModifier("modifier_item_urn_heal")
			and not bot:HasModifier("modifier_item_spirit_vessel_heal")
			and not bot:HasModifier("modifier_juggernaut_healing_ward_heal")
			and not bot:HasModifier("modifier_bottle_regeneration")
			and not bot:HasModifier("modifier_tango_heal")
		then
			dL = mod.GetTeamFountain()
		end
		if dL ~= nil then
			hEffectTarget = dL
			bw = "回复状态"
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if
		bot:HasModifier("modifier_bloodseeker_rupture")
		and ax <= 1
		and mod.GetModifierTime(bot, "modifier_bloodseeker_rupture") >= 3.1
	then
		local ay = mod.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE)
		if #ay <= 1 and abilityItemUsage.CanJuke() then
			dL = mod.GetTeamFountain()
		end
		if dL ~= nil then
			hEffectTarget = dL
			bw = "躲血魔大"
			if unitName == "npc_dota_hero_furion" then
				local dY = bot:GetAbilityByName("furion_teleportation")
				if dY:IsTrained() and dY:IsFullyCastable() then
					bot.useProphetTP = true
					bot.ProphetTPLocation = hEffectTarget
					return BOT_ACTION_DESIRE_NONE
				end
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if abilityItemUsage.IsFarmingAlways(bot) then
		dL = GetAncient(team):GetLocation()
		bw = "处理特殊情况一"
		if unitName == "npc_dota_hero_furion" then
			local dY = bot:GetAbilityByName("furion_teleportation")
			if dY:IsTrained() and dY:IsFullyCastable() then
				bot.useProphetTP = true
				bot.ProphetTPLocation = dL
				return BOT_ACTION_DESIRE_NONE
			end
		end
		return BOT_ACTION_DESIRE_HIGH, dL, bq, bw
	end
	if mod.IsStuck(bot) then
		dL = GetAncient(team):GetLocation()
		bw = "处理特殊情况二"
		if unitName == "npc_dota_hero_furion" then
			local dY = bot:GetAbilityByName("furion_teleportation")
			if dY:IsTrained() and dY:IsFullyCastable() then
				bot.useProphetTP = true
				bot.ProphetTPLocation = dL
				return BOT_ACTION_DESIRE_NONE
			end
		end
		return BOT_ACTION_DESIRE_HIGH, dL, bq, bw
	end
	if mod.Role.ShouldTpToDefend() and bot:DistanceFromFountain() > 3800 then
		dL = GetAncient(team):GetLocation()
		bw = "立即TP守家"
		return BOT_ACTION_DESIRE_HIGH, dL, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_urn_of_shadows"] = function(bm)
	if bm:GetCurrentCharges() == 0 then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 950 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and (
				mod.CanCastOnNonMagicImmune(be)
					and mod.IsInRange(bot, be, bv)
					and not be:HasModifier("modifier_item_urn_damage")
					and not be:HasModifier("modifier_item_spirit_vessel_damage")
					and not be:HasModifier("modifier_arc_warden_tempest_double")
					and (mod.GetHP(be) < 0.95 or mod.IsInRange(bot, be, 700))
				or be:HasModifier("modifier_invoker_cold_snap_freeze")
			)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if bot:GetActiveMode() ~= BOT_MODE_ROSHAN then
		local bU = mod.GetNearbyHeroes(bot, bv + 80, false, BOT_MODE_NONE)
		local c0 = nil
		local c1 = 99999
		for aX, bA in pairs(bU) do
			if
				mod.IsValid(bA)
				and not bA:IsIllusion()
				and bA:DistanceFromFountain() > 800
				and mod.CanCastOnNonMagicImmune(bA)
				and not bA:WasRecentlyDamagedByAnyHero(3.1)
				and not bA:HasModifier("modifier_item_spirit_vessel_heal")
				and not bA:HasModifier("modifier_item_urn_heal")
				and not bA:HasModifier("modifier_fountain_aura")
				and not bA:HasModifier("modifier_arc_warden_tempest_double")
				and bA:OriginalGetMaxHealth() - bA:OriginalGetHealth() > 450
				and #bc == 0
			then
				if bA:OriginalGetHealth() < c1 then
					c0 = bA
					c1 = bA:OriginalGetHealth()
				end
			end
		end
		if c0 ~= nil then
			hEffectTarget = c0
			bw = "治疗:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_veil_of_discord"] = function(bm)
	local bv = 900
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv + 50, true, BOT_MODE_NONE)
	local co = bot:GetNearbyCreeps(bv, true)
	if #co >= 6 or #bx >= 1 then
		hEffectTarget = bot
		bw = "启动希瓦"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
local ei = 0
abilityItemUsage.ConsiderItemDesire["item_ward_sentry"] = function(bm)
	local bv = 500 + b8
	local bq = "ground"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	local dn = bot:GetNearbyTowers(1200, false)
	if mod.IsGoingOnSomeone(bot) and #bx >= 1 then
		local cr = nil
		for aX, br in pairs(bx) do
			if
				mod.IsValidHero(br)
				and mod.IsInRange(bot, br, 900)
				and mod.CanCastOnMagicImmune(br)
				and mod.HasInvisibilityOrItem(br)
				and not br:HasModifier("modifier_slardar_amplify_damage")
				and not br:HasModifier("modifier_item_dustofappearance")
				and not mod.Site.IsLocationHaveTrueSight(br:GetLocation())
			then
				hEffectTarget = mod.GetUnitTowardDistanceLocation(bot, br, bv)
				bw = "插真眼针对:" .. mod.Chat.GetNormName(br)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
local ej = -1
abilityItemUsage.ConsiderItemDesire["item_ironwood_tree"] = function(bm)
	local bv = 600
	local bq = "ground"
	local hEffectTarget = nil
	local bw = nil
	if ej == -1 then
		ej = GetHeroKills(bot:GetPlayerID()) + GetHeroAssists(bot:GetPlayerID())
	end
	if ej < GetHeroKills(bot:GetPlayerID()) + GetHeroAssists(bot:GetPlayerID()) then
		ej = -1
		hEffectTarget = mod.GetFaceTowardDistanceLocation(bot, bv)
		bw = "GG"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_essence_ring"] = function(bm)
	if bot:DistanceFromFountain() < 1000 then
		return 0
	end
	local bv = 600
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, 1400, true, BOT_MODE_NONE)
	if bot:GetMaxHealth() - bot:GetHealth() > 600 and mod.IsAllowedToSpam(bot, 200) then
		hEffectTarget = bot
		bw = "治疗自己"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return abilityItemUsage.ConsiderItemDesire["item_faerie_fire"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_ash_legion_shield"] = function(bm)
	local ek = bm:GetSpecialValueInt("block_radius")
	local el = GetUnitList(UNIT_LIST_ALLIES)
	local em = 0
	local en = 0
	for aX, aR in pairs(el) do
		if mod.IsValid(aR) and mod.IsInRange(bot, aR, ek) then
			local eo = aR:GetUnitName()
			if aR:IsHero() and (aR:IsIllusion() or string.find(eo, "bear")) then
				en = en + 1
			end
			if string.find(eo, "golem") then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
			if
				string.find(eo, "spiderlings")
				or string.find(eo, "forge_spirit")
				or string.find(eo, "golem")
				or string.find(eo, "boar")
				or string.find(eo, "furion_treant")
				or string.find(eo, "familiars")
				or aR:IsDominated()
				or aR:HasModifier("modifier_chen_holy_persuasion")
			then
				em = em + 1
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) and (em >= 2 or en >= 2) then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_flayers_bota"] = function(bm)
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidHero(be) and mod.CanBeAttacked(be) and not mod.IsSuspiciousIllusion(be) and bAttacking then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end
	if mod.IsDoingRoshan(bot) then
		if
			mod.IsRoshan(be)
			and mod.CanBeAttacked(be)
			and mod.IsInRange(bot, be, botAttackRange + 150)
			and #nEnemyHeroes == 0
			and bAttacking
		then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end
	if mod.IsDoingTormentor(bot) then
		if mod.IsTormentor(be) and mod.IsInRange(bot, be, botAttackRange + 150) and #nEnemyHeroes == 0 and bAttacking then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_idol_of_screeauk"] = function(bm)
	if mod.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) and mod.IsRunning(bot) then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_jidi_pollen_bag"] = function(bm)
	local ek = bm:GetSpecialValueInt("debuff_radius")
	local nInRangeEnemy = mod.GetEnemiesNearLoc(botLocation, ek)
	if mod.IsInTeamFight(bot, 1200) then
		if #nInRangeEnemy >= 2 then
			local ep = 0
			for aX, eq in pairs(nInRangeEnemy) do
				if
					mod.IsValidHero(eq)
					and mod.CanBeAttacked(eq)
					and mod.CanCastOnNonMagicImmune(eq)
					and not eq:HasModifier("modifier_doom_bringer_doom_aura_enemy")
					and not eq:HasModifier("modifier_necrolyte_reapers_scythe")
					and not eq:HasModifier("modifier_ice_blast")
					and not eq:HasModifier("modifier_item_spirit_vessel_damage")
				then
					ep = ep + 1
				end
			end
			if ep >= 2 then
				return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanBeAttacked(be)
			and mod.IsInRange(bot, be, ek)
			and mod.CanCastOnNonMagicImmune(be)
			and not be:HasModifier("modifier_doom_bringer_doom_aura_enemy")
			and not be:HasModifier("modifier_necrolyte_reapers_scythe")
			and not be:HasModifier("modifier_ice_blast")
			and not be:HasModifier("modifier_item_spirit_vessel_damage")
		then
			return BOT_ACTION_DESIRE_HIGH, nil, ITEM_TARGET_TYPE_NONE
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_metamorphic_mandible"] = function(bm)
	local er = bm:GetSpecialValueInt("duration")
	if mod.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) then
			local dG = 0
			for aX, eq in pairs(nEnemyHeroes) do
				if
					mod.IsValidHero(eq)
					and not mod.IsSuspiciousIllusion(eq)
					and not eq:HasModifier("modifier_necrolyte_reapers_scythe")
					and not eq:IsChanneling()
				then
					if
						eq:GetAttackTarget() == bot
						or mod.IsChasingTarget(eq, bot)
						or eq:IsFacingLocation(bot:GetLocation(), 15)
						or bot:WasRecentlyDamagedByHero(eq, 3.0)
					then
						dG = dG + eq:GetAttackDamage() * eq:GetAttackSpeed() * er
					end
				end
			end
			if bot:GetActualIncomingDamage(dG * 1.5, DAMAGE_TYPE_PHYSICAL) < bot:GetHealth() then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_riftshadow_prism"] = function(bm)
	local es = bm:GetSpecialValueInt("health_cost")
	if mod.IsGoingOnSomeone(bot) then
		if bot:WasRecentlyDamagedByAnyHero(2.0) and mod.GetHealthAfter(bot:GetHealth() * es) > 0.2 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_spider_legs"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_phase_boots"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_flicker"] = function(bm)
	if bot:DistanceFromFountain() < 600 or bot:IsRooted() then
		return BOT_ACTION_DESIRE_NONE
	end
	local bv = 600
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, 800, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidHero(be) and (bot:IsSilenced() or bot:IsRooted()) then
			hEffectTarget = bot
			bw = "驱散沉默或缠绕"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.IsRetreating(bot) and bot:WasRecentlyDamagedByAnyHero(3.0) and #bx >= 1 then
		hEffectTarget = bot
		bw = "撤退"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_illusionsts_cape"] = function(bm)
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	if mod.IsValid(be) and mod.IsInRange(bot, be, bv) then
		hEffectTarget = be
		bw = "辅助攻击"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return abilityItemUsage.ConsiderItemDesire["item_manta"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_woodland_striders"] = function(bm)
	if bot:DistanceFromFountain() < 600 then
		return 0
	end
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	if mod.IsRetreating(bot) and bot:WasRecentlyDamagedByAnyHero(4.0) then
		hEffectTarget = bot
		bw = "撤退"
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_fallen_sky"] = function(bm)
	local bv = 1600
	local bq = "ground"
	local ek = 315
	local et = 0.5
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		local eu = mod.GetAoeEnemyHeroLocation(bot, bv, ek, 2)
		if eu ~= nil then
			hEffectTarget = eu
			bw = "Aoe"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if mod.IsValidHero(be) and mod.CanCastOnNonMagicImmune(be) and mod.IsInRange(bot, be, bv) then
			local ev = mod.GetDelayCastLocation(bot, be, bv, ek, et)
			if ev ~= nil then
				hEffectTarget = ev
				bw = "进攻"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if mod.IsRetreating(bot) and bot:WasRecentlyDamagedByAnyHero(3.0) then
		local bK = mod.GetLocationTowardDistanceLocation(bot, GetAncient(team):GetLocation(), 1600)
		local e6 = mod.GetNearbyHeroes(bot, 800, false, BOT_MODE_ATTACK)
		if
			bot:DistanceFromFountain() > 800
			and IsLocationPassable(bK)
			and (#e6 == 0 or bot:GetActiveModeDesire() > BOT_MODE_DESIRE_VERYHIGH * 0.9)
			and #bx >= 1
		then
			hEffectTarget = bK
			bw = "撤退"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_ex_machina"] = function(bm)
	local bv = 800
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidHero(be) then
			local ew = { 0, 1, 2, 3, 4, 5 }
			local ex = 0
			for aX, bl in pairs(ew) do
				local bm = bot:GetItemInSlot(bl)
				if bm ~= nil and bm:GetName() ~= "item_refresher" then
					local ey = bm:GetCooldownTimeRemaining()
					ex = ex + ey
				end
			end
			if ex >= 30 then
				hEffectTarget = be
				bw = "刷新CD"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_stormcrafter"] = function(bm)
	local bv = 300 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, 1600, true, BOT_MODE_NONE)
	if mod.CanCastOnNonMagicImmune(bot) and #bx > 0 then
		if bot:IsRooted() or bot:GetPrimaryAttribute() == ATTRIBUTE_INTELLECT and bot:IsSilenced() then
			hEffectTarget = bot
			bw = "解缠绕:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if mod.IsUnitTargetProjectileIncoming(bot, 400) then
			hEffectTarget = bot
			bw = "防御弹道:" .. mod.Chat.GetNormName(hEffectTarget)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_gungir"] = function(bm)
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 1000)
	for aX, eq in pairs(nInRangeEnemy) do
		if
			mod.IsValidTarget(eq)
			and mod.IsUnitWillGoInvisible(eq)
			and mod.IsClosestToDustLocation(bot, eq:GetLocation())
			and not mod.HasInvisCounterBuff(eq)
			and not mod.IsSuspiciousIllusion(eq)
		then
			if bm:GetName() == "item_gungir" then
				hEffectTarget = eq:GetLocation()
			end
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, "unit", "Stop invis"
		end
	end
	return abilityItemUsage.ConsiderItemDesire["item_rod_of_atos"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_pogo_stick"] = function(bm)
	local bv = 1000
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.IsInRange(bot, be, bot:GetAttackRange() + 400)
			and mod.CanCastOnMagicImmune(be)
			and mod.IsChasingTarget(bot, be)
		then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(be)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if bf == BOT_MODE_RETREAT and bot:GetActiveModeDesire() > BOT_MODE_DESIRE_HIGH then
		if bot:IsFacingLocation(GetAncient(team):GetLocation(), 20) and bot:DistanceFromFountain() > 600 and #bx >= 1 then
			hEffectTarget = bot
			bw = "撤退了推自己"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_paintball"] = function(bm)
	local bv = 900 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		mod.IsValidHero(be)
		and mod.CanCastOnNonMagicImmune(be)
		and mod.CanCastOnTargetAdvanced(be)
		and mod.IsInRange(be, bot, bv)
	then
		hEffectTarget = be
		bw = "仙灵榴弹:" .. mod.Chat.GetNormName(hEffectTarget)
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_heavy_blade"] = function(bm)
	local bv = 500
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	for i12 = 1, #GetTeamPlayers(GetTeam()) do
		local bA = GetTeamMember(i12)
		if mod.IsValidHero(bA) and mod.IsInRange(bot, bA, bv + 100) then
			if
				(mod.IsGoingOnSomeone(bA) or mod.IsRetreating(bA))
				and bA:WasRecentlyDamagedByAnyHero(2.0)
				and mod.GetHP(bA) < 0.85
			then
				local d7 = mod.GetNearbyHeroes(bA, 300, true, BOT_MODE_NONE)
				local br = d7[1]
				if mod.IsValidHero(br) and mod.CanCastOnMagicImmune(br) then
					hEffectTarget = bA
					bw = "行巫之祸驱散友军:" .. mod.Chat.GetNormName(bA)
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				end
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidHero(be) and mod.IsInRange(bot, be, bv) and mod.CanCastOnNonMagicImmune(be) then
			if be:WasRecentlyDamagedByAnyHero(3.0) and mod.GetHP(be) < 0.7 then
				hEffectTarget = be
				bw = "行巫之祸驱散敌军:" .. mod.Chat.GetNormName(be)
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_revenants_brooch"] = function(bm)
	local bv = bot:GetAttackRange() + 100
	local bq = "none"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidHero(be) and mod.IsInRange(bot, be, bv) then
			hEffectTarget = bot
			bw = "亡魂胸针进攻:" .. mod.Chat.GetNormName(be)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_wraith_pact"] = function(bm)
	local bv = 200 + b8
	local bq = "ground"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and be:GetAttackTarget() ~= nil
			and mod.IsInRange(bot, be, 900)
			and mod.CanCastOnNonMagicImmune(be)
		then
			hEffectTarget = mod.GetFaceTowardDistanceLocation(bot, 200)
			bw = "怨灵之契进攻:" .. mod.Chat.GetNormName(be)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_boots_of_bearing"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_ancient_janggo"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_new"] = function(bm)
	local bv = 300 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidHero(be) then
			hEffectTarget = be
			bw = "进攻:" .. mod.Chat.GetNormName(be)
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_soul_ring"] = function(aT)
	local bq = "none"
	local hEffectTarget = bot
	local bw = nil
	local ez = bot:GetActiveMode()
	local eA = bot:GetMana() / bot:GetMaxMana()
	local eB = bot:OriginalGetHealth() / bot:OriginalGetMaxHealth()
	if (ez == BOT_MODE_FARM or ez == BOT_MODE_LANING) and eB > 0.5 and eA < 0.5 then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_pavise"] = function(aT)
	local bv = 1000 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local cz = mod.GetNearbyHeroes(bot, bv, false, BOT_MODE_NONE)
	local eC = bot:OriginalGetHealth() / bot:OriginalGetMaxHealth()
	for aX, bA in pairs(cz) do
		if
			mod.IsValidHero(bA)
			and bA ~= bot
			and not bA:IsMagicImmune()
			and not bA:IsInvulnerable()
			and not bA:IsIllusion()
			and not bA:HasModifier("modifier_item_pavise_shield")
			and not bA:HasModifier("modifier_antimage_spell_shield")
			and (mod.IsUnitTargetProjectileIncoming(bA, 800) or mod.IsWillBeCastUnitTargetSpell(bA, 1200) or eC < 0.2)
		then
			hEffectTarget = bA
			bw = "帮助队友"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.IsValidHero(be) and mod.IsInRange(bot, be, 2400) and not mod.IsInRange(bot, be, 800) then
		if #cz >= 2 then
			local cJ = nil
			local da = 9999
			for aX, bA in pairs(cz) do
				if
					bA ~= bot
					and not bA:IsIllusion()
					and mod.IsInRange(bA, be, da)
					and not bA:HasModifier("modifier_item_pavise_shield")
					and not bA:HasModifier("modifier_antimage_spell_shield")
				then
					cJ = bA
					da = GetUnitToUnitDistance(be, bA)
					if mod.IsHumanPlayer(bA) then
						break
					end
				end
			end
			if cJ ~= nil then
				hEffectTarget = cJ
				bw = "先给前排套上"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_harpoon"] = function(aT)
	local bv = 700 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local eD = bot:GetAttackRange()
	local be = mod.GetProperTarget(bot)
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidTarget(be)
			and mod.IsInRange(bot, be, bv + eD)
			and not mod.IsInRange(bot, be, bv / 2)
			and not mod.IsSuspiciousIllusion(be)
		then
			hEffectTarget = be
			bw = "Harpoon"
			if mod.WeAreStronger(bot, bv + eD) then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			else
				return BOT_ACTION_DESIRE_MODERATE, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_disperser"] = function(aT)
	local bv = 600 + b8
	local bq = "unit"
	local hEffectTarget = nil
	local bw = nil
	local eD = bot:GetAttackRange()
	local be = mod.GetProperTarget(bot)
	local nAllyHeroes = mod.GetNearbyHeroes(bot, bv, false, BOT_MODE_NONE)
	local nEnemyHeroes = mod.GetNearbyHeroes(bot, bv + eD, true, BOT_MODE_NONE)
	if mod.IsDisabled(bot) then
		if nEnemyHeroes ~= nil and #nEnemyHeroes >= 1 then
			hEffectTarget = bot
			bw = "Disperser"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	for aX, eE in pairs(nAllyHeroes) do
		if
			nEnemyHeroes ~= nil
			and #nEnemyHeroes >= 1
			and eE:WasRecentlyDamagedByAnyHero(2)
			and not mod.IsSuspiciousIllusion(eE)
		then
			hEffectTarget = eE
			bw = "Disperser"
			if mod.IsDisabled(eE) then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if eE:GetActiveMode() == BOT_MODE_RETREAT and mod.GetHP(eE) < 0.42 then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidTarget(be)
			and mod.CanCastOnNonMagicImmune(be)
			and mod.IsInRange(bot, be, bv)
			and not mod.IsSuspiciousIllusion(be)
			and not mod.IsDisabled(be)
		then
			if
				be:GetCurrentMovementSpeed() > bot:GetCurrentMovementSpeed()
				and bot:IsFacingLocation(be:GetLocation(), 30)
				and not be:IsFacingLocation(bot:GetLocation(), 30)
			then
				hEffectTarget = RandomInt(1, 100) > 20 and be or bot
				bw = "Disperser"
				if mod.WeAreStronger(bot, bv + eD) then
					return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
				else
					return BOT_ACTION_DESIRE_MODERATE, hEffectTarget, bq, bw
				end
			end
		end
	end
	if mod.IsInTeamFight(bot, bv + eD) then
		local eF = mod.GetAlliesNearLoc(bot:GetLocation(), bv)
		if eF ~= nil and #eF >= 1 and nEnemyHeroes ~= nil and #nEnemyHeroes >= 2 then
			hEffectTarget = bot
			bw = "Disperser"
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
	end
	if mod.IsRetreating(bot) then
		if nEnemyHeroes ~= nil and #nEnemyHeroes >= 1 then
			if not mod.WeAreStronger(bot, bv + eD) or mod.GetHP(bot) < 0.33 then
				hEffectTarget = RandomInt(1, 100) > 10 and bot or be
				bw = "Disperser"
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_blood_grenade"] = function(aT)
	local bv = 900
	local ek = 300
	local eG = bot:GetHealth()
	local eH = 75
	local eI = 50
	local eJ = 15
	local er = 5
	local nEnemyHeroes = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	local eK = eI + eJ * er
	for aX, eq in pairs(nEnemyHeroes) do
		local eL = mod.CanKillTarget(eq, eK, DAMAGE_TYPE_MAGICAL)
		if mod.IsInRange(bot, eq, bot:GetAttackRange()) and bot:IsFacingLocation(eq:GetLocation(), 15) then
			eL = eL or mod.CanKillTarget(eq, eK + 150, DAMAGE_TYPE_MAGICAL)
		end
		if
			mod.IsValidHero(eq)
			and mod.CanCastOnNonMagicImmune(eq)
			and eL
			and not mod.IsSuspiciousIllusion(eq)
			and eG > eH * 2
		then
			local nInRangeEnemy = mod.GetEnemiesNearLoc(eq:GetLocation(), ek)
			if nInRangeEnemy ~= nil and #nInRangeEnemy >= 1 then
				return BOT_ACTION_DESIRE_HIGH, mod.GetCenterOfUnits(nInRangeEnemy), "ground", "Blood Grenade"
			end
			return BOT_ACTION_DESIRE_HIGH, eq:GetLocation(), "ground", "Blood Grenade"
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		for aX, eq in pairs(nEnemyHeroes) do
			if
				mod.IsValidHero(eq)
				and mod.CanCastOnNonMagicImmune(eq)
				and mod.IsChasingTarget(bot, eq)
				and not mod.IsSuspiciousIllusion(eq)
				and eG > eH * 2
			then
				local bE = mod.GetNearbyHeroes(eq, 1200, true, BOT_MODE_NONE)
				local nInRangeEnemy = mod.GetNearbyHeroes(eq, 1200, false, BOT_MODE_NONE)
				if
					bE ~= nil
					and nInRangeEnemy ~= nil
					and #bE >= #nInRangeEnemy
					and #bE >= 1
					and mod.IsGoingOnSomeone(bE[1])
					and bE[1]:GetAttackTarget() == eq
					and mod.IsChasingTarget(bE[1], eq)
					and not bE[1]:IsIllusion()
					and mod.GetTotalEstimatedDamageToTarget(bE, eq) >= eq:GetHealth()
				then
					local eM = mod.GetEnemiesNearLoc(eq:GetLocation(), ek)
					if eM ~= nil and #eM >= 1 then
						return BOT_ACTION_DESIRE_HIGH, mod.GetCenterOfUnits(eM), "ground", "Blood Grenade"
					end
					return BOT_ACTION_DESIRE_HIGH, eq:GetLocation(), "ground", "Blood Grenade"
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE, 0
end
local eN = 0
abilityItemUsage.ConsiderItemDesire["item_smoke_of_deceit"] = function(aT)
	local ek = 1200
	local bq = "none"
	local hEffectTarget = nil
	local bw = "Smoke Of Deceit"
	local eO = false
	local bE = mod.GetAllyList(bot, ek)
	local nInRangeEnemy = mod.GetNearbyHeroes(bot, ek, true, BOT_MODE_NONE)
	local eP = bot:GetNearbyTowers(ek, true)
	if DotaTime() < 0 and DotaTime() > -60 then
		return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
	end
	if nInRangeEnemy ~= nil and #nInRangeEnemy == 0 or eP ~= nil and #eP == 0 then
		for aX, eE in pairs(bE) do
			if mod.IsValidHero(eE) then
				local eQ = mod.GetNearbyHeroes(eE, ek, true, BOT_MODE_NONE)
				local eR = eE:GetNearbyTowers(ek, true)
				if eQ ~= nil and #eQ >= 1 or eR ~= nil and #eR >= 1 then
					eO = true
					break
				end
			end
		end
	end
	if not eO then
		local bf = bot:GetActiveMode()
		local eS = mod.CheckTimeOfDay()
		hEffectTarget = bot
		if #bE >= 2 and (bf == BOT_MODE_ROAM or bf == BOT_MODE_GANK) then
			return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
		end
		if
			eS == "day" and GetUnitToLocationDistance(bot, mod.Utils.RadiantRoshanLoc) < 600
			or eS == "night" and GetUnitToLocationDistance(bot, mod.Utils.DireRoshanLoc) < 600
		then
			if GetRoshanKillTime() > eN then
				eN = GetRoshanKillTime()
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
		if bf == BOT_MODE_ROSHAN and bE ~= nil and #bE >= 2 then
			if eS == "day" and GetUnitToLocationDistance(bot, mod.Utils.RadiantRoshanLoc) > 3000 then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
			if eS == "night" and GetUnitToLocationDistance(bot, mod.Utils.DireRoshanLoc) > 3000 then
				return BOT_ACTION_DESIRE_HIGH, hEffectTarget, bq, bw
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
local eT = nil
abilityItemUsage.ConsiderItemDesire["item_dust"] = function(aT)
	local ek = 1050
	if eT == nil then
		eT = GetTeamPlayers(GetOpposingTeam())
	end
	local df = bot:GetNearbyTrees(500)
	if #df < 5 then
		for aX, loopVar8 in pairs(eT) do
			local val47 = GetHeroLastSeenInfo(loopVar8)
			if IsHeroAlive(loopVar8) and val47 ~= nil then
				local val48 = val47[1]
				if
					val48 ~= nil
					and val48.time_since_seen > 0.2
					and val48.time_since_seen < 0.5
					and GetUnitToLocationDistance(bot, val48.location) < ek - 450
					and mod.IsClosestToDustLocation(bot, val48.location)
				then
					local bD = mod.GetXUnitsTowardsLocation2(val48.location, direBase, 200)
					if team == TEAM_DIRE then
						bD = mod.GetXUnitsTowardsLocation2(val48.location, radiantBase, 200)
					end
					if IsLocationVisible(bD) and IsLocationPassable(bD) then
						return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
					end
				end
			end
		end
	end
	if
		bot:HasModifier("modifier_sandking_sand_storm_slow")
		or bot:HasModifier("modifier_sandking_sand_storm_slow_aura_thinker")
	then
		return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
	end
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), ek)
	if nInRangeEnemy ~= nil and #nInRangeEnemy == 0 then
		if bot:HasModifier("modifier_item_radiance_debuff") then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
		for aX, loopVar9 in pairs(eT) do
			if IsHeroAlive(loopVar9) and bot:WasRecentlyDamagedByPlayer(loopVar9, 0.5) then
				local val49 = GetHeroLastSeenInfo(loopVar9)
				if val49 ~= nil then
					local val50 = val49[1]
					if val50 ~= nil and GetUnitToLocationDistance(bot, val50.location) < ek then
						return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
					end
				end
			end
		end
	else
		for aX, eq in pairs(nInRangeEnemy) do
			if
				mod.IsValidTarget(eq)
				and mod.IsUnitWillGoInvisible(eq)
				and mod.IsClosestToDustLocation(bot, eq:GetLocation())
				and not mod.HasInvisCounterBuff(eq)
				and not mod.IsSuspiciousIllusion(eq)
			then
				local eU = eq:GetNearbyTowers(700, true)
				if eU == nil or #eU == 0 then
					return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_trusty_shovel"] = function(bm)
	if GetTeamMember(1):IsBot() then
		return BOT_ACTION_DESIRE_NONE
	end
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 1000)
	if nInRangeEnemy ~= nil and #nInRangeEnemy == 0 then
		return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), "ground", nil
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_arcane_ring"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_arcane_boots"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_unstable_wand"] = function(bm)
	local bv = 1600
	local nInRangeEnemy = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if
		nInRangeEnemy ~= nil
		and #nInRangeEnemy == 0
		and mod.GetMP(bot) > 0.5
		and (mod.IsRetreating(bot) or mod.IsGoingOnSomeone(bot))
	then
		return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_seeds_of_serenity"] = function(bm)
	local ek = 400
	local nInRangeEnemy = mod.GetNearbyHeroes(bot, ek, true, BOT_MODE_NONE)
	local eP = bot:GetNearbyTowers(700, true)
	if mod.IsFarming(bot) then
		if mod.IsAttacking(bot) then
			local eV = bot:GetNearbyNeutralCreeps(ek)
			if eV ~= nil and (#eV >= 3 or #eV >= 2 and eV[1]:IsAncientCreep()) then
				return BOT_ACTION_DESIRE_HIGH, bot:GetLocation()
			end
			local bH = bot:GetNearbyLaneCreeps(ek, true)
			if bH ~= nil and #bH >= 3 then
				return BOT_ACTION_DESIRE_HIGH, bot:GetLocation()
			end
		end
	end
	if mod.IsPushing(bot) then
		if
			eP ~= nil
			and #eP >= 1
			and mod.IsValidBuilding(be)
			and mod.IsValidBuilding(eP[1])
			and mod.IsAttacking(bot)
			and be == eP[1]
		then
			return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), "ground", nil
		end
	end
	if mod.IsDoingRoshan(bot) then
		if mod.IsRoshan(be) and mod.IsInRange(bot, be, ek) and mod.IsAttacking(bot) then
			return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), "ground", nil
		end
	end
	if mod.IsDoingTormentor(bot) then
		if mod.IsTormentor(be) and mod.IsInRange(bot, be, ek) and mod.IsAttacking(bot) then
			return BOT_ACTION_DESIRE_HIGH, bot:GetLocation(), "ground", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_dagger_of_ristul"] = function(bm)
	local bq = "none"
	if mod.GetHP(bot) < 0.4 then
		return BOT_ACTION_DESIRE_NONE
	end
	if mod.IsGoingOnSomeone(bot) then
		if mod.IsValidTarget(be) and mod.IsInRange(bot, be, 800) and mod.GetHP(bot) > 0.5 then
			return BOT_ACTION_DESIRE_HIGH, bot, bq, nil
		end
	end
	if mod.IsFarming(bot) and mod.IsAttacking(bot) and mod.GetHP(bot) > 0.7 then
		local eV = bot:GetNearbyNeutralCreeps(600)
		if eV ~= nil and #eV >= 2 then
			return BOT_ACTION_DESIRE_HIGH, bot, bq, nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_stonefeather_satchel"] = function(bm)
	local bq = "none"
	local nEnemyHeroes = mod.GetNearbyHeroes(bot, 1200, true, BOT_MODE_NONE)
	if
		#nEnemyHeroes >= 1
		and (mod.IsRetreating(bot) or mod.GetHP(bot) < 0.5)
		and not bot:HasModifier("modifier_item_stonefeather_satchel_rocks")
	then
		return BOT_ACTION_DESIRE_HIGH, bot, bq, nil
	end
	if #nEnemyHeroes == 0 and not bot:HasModifier("modifier_item_stonefeather_satchel_feathers") then
		return BOT_ACTION_DESIRE_MODERATE, bot, bq, nil
	end
	return BOT_ACTION_DESIRE_NONE
end
local eW = nil
abilityItemUsage.ConsiderItemDesire["item_royal_jelly"] = function(bm)
	if eW == nil then
		eW = DotaTime()
	else
		if eW < DotaTime() - 2.0 then
			local cJ = nil
			for i13 = 1, #GetTeamPlayers(GetTeam()) do
				local eE = GetTeamMember(i13)
				if
					mod.IsValidHero(eE)
					and mod.IsCore(eE)
					and not eE:IsIllusion()
					and not eE:HasModifier("modifier_royal_jelly")
				then
					cJ = eE
				end
			end
			if cJ ~= nil then
				eW = nil
				return BOT_ACTION_DESIRE_HIGH, cJ, "unit", nil
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_bullwhip"] = function(bm)
	local bv = 850 + b8
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanCastOnNonMagicImmune(be)
			and mod.IsChasingTarget(bot, be)
			and not mod.IsDisabled(be)
		then
			return BOT_ACTION_DESIRE_HIGH, be, "unit", nil
		end
	end
	local bE = mod.GetAlliesNearLoc(bot:GetLocation(), bv)
	for aX, eE in pairs(bE) do
		if mod.IsValidHero(eE) and mod.CanCastOnNonMagicImmune(eE) then
			local eQ = mod.GetNearbyHeroes(eE, 1200, true, BOT_MODE_NONE)
			if
				eQ ~= nil
				and #eQ >= 1
				and mod.IsRetreating(eE)
				and eE:DistanceFromFountain() > 1200
				and not mod.IsRealInvisible(eE)
				and not mod.IsDisabled(eE)
			then
				return BOT_ACTION_DESIRE_HIGH, eE, "unit", nil
			end
		end
	end
	if bm:IsFullyCastable() then
		return BOT_ACTION_DESIRE_HIGH, bot, "unit", nil
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_light_collector"] = function(bm)
	local ek = 325
	local eX = bot:GetNearbyTrees(ek)
	if mod.IsGoingOnSomeone(bot) then
		if eX ~= nil and #eX >= 3 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_iron_talon"] = function(bm)
	local bv = 350
	if mod.IsFarming(bot) then
		local eY = bot:GetNearbyNeutralCreeps(bv)
		if #eY <= 0 then
			return 0
		end
		local eZ = mod.GetMostHpUnit(eY)
		if mod.CanBeAttacked(eZ) and mod.GetHP(eZ) > 0.5 then
			return BOT_ACTION_DESIRE_HIGH, eZ, "unit", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_craggy_coat"] = function(bm)
	local ek = 1200
	if mod.IsInTeamFight(bot) then
		local e_ = mod.GetEnemiesNearLoc(bot:GetLocation(), ek)
		if e_ ~= nil and #e_ >= 2 and bot:WasRecentlyDamagedByAnyHero(1.5) then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		local bE = mod.GetNearbyHeroes(bot, 1200, false, BOT_MODE_NONE)
		if
			mod.IsValidTarget(be)
			and mod.IsAttacking(be)
			and bot:WasRecentlyDamagedByAnyHero(1.3)
			and mod.IsInRange(bot, be, 600)
			and not mod.IsSuspiciousIllusion(be)
		then
			local eM = mod.GetNearbyHeroes(be, 1200, false, BOT_MODE_NONE)
			if bE ~= nil and eM ~= nil and #bE >= #eM then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
		end
	end
	if mod.IsDoingRoshan(bot) then
		if mod.IsRoshan(be) and mod.IsInRange(bot, be, 500) and mod.IsAttacking(bot) then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsDoingTormentor(bot) then
		if mod.IsTormentor(be) and mod.IsInRange(bot, be, 500) and mod.IsAttacking(bot) then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_psychic_headband"] = function(bm)
	local bv = 600 + b8
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), bv)
	if mod.IsRetreating(bot) then
		if
			mod.IsValidHero(nInRangeEnemy[1])
			and mod.CanCastOnNonMagicImmune(nInRangeEnemy[1])
			and mod.IsRunning(nInRangeEnemy[1])
			and nInRangeEnemy[1]:IsFacingLocation(bot:GetLocation(), 30)
			and not mod.IsSuspiciousIllusion(nInRangeEnemy[1])
			and not mod.IsDisabled(nInRangeEnemy[1])
		then
			return BOT_ACTION_DESIRE_HIGH, nInRangeEnemy[1], "unit", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_ogre_seal_totem"] = function(bm)
	local f0 = 275
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), f0 * 2)
	if mod.IsGoingOnSomeone(bot) then
		local bE = mod.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE)
		if
			mod.IsValidTarget(be)
			and mod.CanCastOnNonMagicImmune(be)
			and bot:IsFacingLocation(be:GetLocation(), 5)
			and mod.IsInRange(bot, be, f0 * 2)
			and not mod.IsInRange(bot, be, f0 - 75)
			and not mod.IsSuspiciousIllusion(be)
			and not bot:HasModifier("modifier_abaddon_borrowed_time")
			and not bot:HasModifier("modifier_necrolyte_reapers_scythe")
			and not mod.IsLocationInChrono(be:GetLocation())
			and not mod.IsLocationInBlackHole(be:GetLocation())
		then
			local eM = mod.GetNearbyHeroes(be, 1000, false, BOT_MODE_NONE)
			if bE ~= nil and eM ~= nil and #bE >= #eM then
				return BOT_ACTION_DESIRE_HIGH, bot, "unit", nil
			end
		end
	end
	if mod.IsRetreating(bot) then
		if
			mod.IsValidHero(nInRangeEnemy[1])
			and mod.IsRunning(nInRangeEnemy[1])
			and bot:IsFacingLocation(mod.GetEscapeLoc(), 15)
			and nInRangeEnemy[1]:IsFacingLocation(bot:GetLocation(), 30)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
local f1 = "health"
abilityItemUsage.ConsiderItemDesire["item_doubloon"] = function(bm)
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 1000)
	if mod.IsGoingOnSomeone(bot) then
		local bE = mod.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE)
		if
			mod.IsValidTarget(be)
			and mod.IsInRange(bot, be, 1000)
			and mod.GetHP(bot) > 0.8
			and mod.GetMP(bot) < 0.5
			and f1 == "mana"
			and not mod.IsSuspiciousIllusion(be)
		then
			f1 = "health"
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsRetreating(bot) then
		if
			mod.IsValidHero(nInRangeEnemy[1])
			and mod.IsRunning(nInRangeEnemy[1])
			and nInRangeEnemy[1]:IsFacingLocation(bot:GetLocation(), 30)
			and bot:WasRecentlyDamagedByAnyHero(1.5)
			and mod.GetHP(bot) < 0.5
			and mod.GetMP(bot) > 0.75
			and f1 == "health"
		then
			f1 = "mana"
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_ninja_gear"] = function(bm)
	local bv = 1600
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidTarget(be)
			and mod.CanCastOnMagicImmune(be)
			and mod.IsInRange(bot, be, 2800)
			and not mod.IsInRange(bot, be, be:GetCurrentVisionRange() + 200)
			and not mod.IsSuspiciousIllusion(be)
		then
			local bH = bot:GetNearbyLaneCreeps(800, true)
			local eU = bot:GetNearbyTowers(700, true)
			if bH ~= nil and #bH == 0 and eU ~= nil and #eU == 0 then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
		end
	end
	if mod.IsDefending(bot) then
		local bf = bot:GetActiveMode()
		local dz = LANE_MID
		if bf == BOT_MODE_PUSH_TOWER_TOP then
			dz = LANE_TOP
		end
		if bf == BOT_MODE_PUSH_TOWER_BOT then
			dz = LANE_BOT
		end
		local f2 = GetLaneFrontLocation(team, dz, 0)
		if GetUnitToLocationDistance(bot, f2) > 3200 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsDoingRoshan(bot) then
		if mod.CheckTimeOfDay() == "day" and GetUnitToLocationDistance(bot, mod.Utils.RadiantRoshanLoc) > 3200 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
		if mod.CheckTimeOfDay() == "night" and GetUnitToLocationDistance(bot, mod.Utils.DireRoshanLoc) > 3200 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsDoingTormentor(bot) and GetUnitToLocationDistance(bot, mod.GetTormentorLocation(GetTeam())) > 3200 then
		return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_trickster_cloak"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_invis_sword"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_havoc_hammer"] = function(bm)
	local ek = 400
	local bZ = 175 + bot:GetAttributeValue(ATTRIBUTE_STRENGTH) * 1.5
	local nEnemyHeroes = mod.GetNearbyHeroes(bot, ek, true, BOT_MODE_NONE)
	for aX, eq in pairs(nEnemyHeroes) do
		if
			mod.IsValidHero(eq)
			and mod.CanCastOnNonMagicImmune(eq)
			and mod.CanKillTarget(eq, bZ, DAMAGE_TYPE_MAGICAL)
			and not mod.IsSuspiciousIllusion(eq)
			and not eq:HasModifier("modifier_abaddon_borrowed_time")
			and not eq:HasModifier("modifier_dazzle_shallow_grave")
			and not eq:HasModifier("modifier_oracle_false_promise_timer")
			and not eq:HasModifier("modifier_templar_assassin_refraction_absorb")
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsInTeamFight(bot, 1200) then
		local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 1000)
		if nInRangeEnemy ~= nil and #nInRangeEnemy >= 2 then
			local e_ = mod.GetEnemiesNearLoc(bot:GetLocation(), ek)
			if
				e_ ~= nil
				and #e_ >= 2
				and not mod.IsLocationInChrono(nInRangeEnemy[1]:GetLocation())
				and not mod.IsLocationInBlackHole(nInRangeEnemy[1]:GetLocation())
			then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		local bE = mod.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE)
		if
			mod.IsValidTarget(be)
			and mod.CanCastOnNonMagicImmune(be)
			and mod.IsInRange(bot, be, ek)
			and mod.IsRunning(be)
			and bot:IsFacingLocation(be:GetLocation(), 30)
			and not be:IsFacingLocation(bot:GetLocation(), 90)
			and not mod.IsSuspiciousIllusion(be)
			and not mod.IsDisabled(be)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsDoingRoshan(bot) then
		if mod.IsRoshan(be) and mod.IsInRange(bot, be, ek) and mod.IsAttacking(bot) then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsDoingTormentor(bot) then
		if mod.IsTormentor(be) and mod.IsInRange(bot, be, ek) and mod.IsAttacking(bot) then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_martyrs_plate"] = function(bm)
	local ek = 900
	if mod.IsInTeamFight(bot) then
		local bE = mod.GetAlliesNearLoc(bot:GetLocation(), ek)
		local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), ek)
		if nInRangeEnemy ~= nil and #nInRangeEnemy >= 2 then
			if
				mod.IsValidHero(nInRangeEnemy[1])
				and mod.IsValidHero(nInRangeEnemy[2])
				and mod.IsAttacking(nInRangeEnemy[1])
				and mod.IsAttacking(nInRangeEnemy[2])
				and mod.GetHP(bot) > 0.88
				and bot:GetHealth() >= 3800
				and not bot:WasRecentlyDamagedByAnyHero(0.8)
			then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_force_boots"] = function(bm)
	local bv = 700 + b8
	local nInRangeEnemy = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsStuck(bot) then
		return BOT_ACTION_DESIRE_HIGH, bot, "unit", nil
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidTarget(be)
			and mod.IsInRange(bot, be, 900)
			and abilityItemUsage.IsWithoutSpellShield(be)
			and not mod.IsSuspiciousIllusion(be)
			and not mod.IsLocationInChrono(be:GetLocation())
			and not mod.IsLocationInBlackHole(be:GetLocation())
			and not be:HasModifier("modifier_necrolyte_reapers_scythe")
		then
			local bE = mod.GetNearbyHeroes(bot, 1200, false, BOT_MODE_NONE)
			local eM = mod.GetNearbyHeroes(be, 1200, false, BOT_MODE_NONE)
			if bE ~= nil and eM ~= nil and #bE >= #eM then
				if bot:IsFacingLocation(be:GetLocation(), 15) and #bE >= #eM + 1 then
					return BOT_ACTION_DESIRE_HIGH, bot, "unit", nil
				end
				local ck = mod.GetCenterOfUnits(bE)
				if be:IsFacingLocation(ck, 15) and GetUnitToLocationDistance(bot, ck) >= 750 then
					return BOT_ACTION_DESIRE_HIGH, be, "unit", nil
				end
			end
		end
	end
	if mod.IsRetreating(bot) then
		if
			nInRangeEnemy ~= nil
			and #nInRangeEnemy >= 1
			and bot:IsFacingLocation(mod.GetEscapeLoc(), 30)
			and bot:DistanceFromFountain() > 600
			and not mod.IsRealInvisible(bot)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "unit", nil
		end
	end
	local bE = mod.GetAlliesNearLoc(bot:GetLocation(), bv)
	for aX, eE in pairs(bE) do
		if mod.IsValidHero(eE) and mod.CanCastOnNonMagicImmune(eE) then
			local eQ = mod.GetNearbyHeroes(eE, 1200, true, BOT_MODE_NONE)
			if
				eQ ~= nil
				and #eQ >= 1
				and mod.IsRetreating(eE)
				and eE:IsFacingLocation(mod.GetEscapeLoc(), 30)
				and eE:DistanceFromFountain() > 600
				and eE:WasRecentlyDamagedByAnyHero(2.2)
				and not mod.IsRealInvisible(eE)
			then
				return BOT_ACTION_DESIRE_HIGH, eE, "unit", nil
			end
			if mod.IsGoingOnSomeone(eE) then
				local d9 = mod.GetProperTarget(eE)
				if
					mod.IsValidHero(d9)
					and mod.CanCastOnNonMagicImmune(d9)
					and eE:IsFacingLocation(d9:GetLocation(), 15)
					and GetUnitToUnitDistance(eE, d9) > eE:GetAttackRange() + 50
					and GetUnitToUnitDistance(eE, d9) < eE:GetAttackRange() + 700
					and mod.IsRunning(d9)
					and mod.GetEnemyCount(eE, 1600) <= 3
					and not d9:IsFacingLocation(eE:GetLocation(), 40)
					and not mod.IsSuspiciousIllusion(d9)
				then
					return BOT_ACTION_DESIRE_HIGH, eE, "unit", nil
				end
			end
			if mod.IsStuck(eE) then
				return BOT_ACTION_DESIRE_HIGH, eE, "unit", nil
			end
		end
	end
	if bot:DistanceFromFountain() < 2800 then
		for aX, eq in pairs(nInRangeEnemy) do
			if
				mod.IsValidHero(eq)
				and mod.CanCastOnMagicImmune(eq)
				and eq:IsFacingLocation(GetAncient(team):GetLocation(), 30)
				and GetUnitToLocationDistance(eq, GetAncient(team):GetLocation()) < 1600
				and not mod.IsSuspiciousIllusion(eq)
			then
				local bE = mod.GetNearbyHeroes(bot, 1000, false, BOT_MODE_NONE)
				local eM = mod.GetNearbyHeroes(eq, 1000, false, BOT_MODE_NONE)
				if bE ~= nil and eM ~= nil and #bE >= #eM then
					return BOT_ACTION_DESIRE_HIGH, eq, "unit", nil
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_seer_stone"] = function(bm)
	local ek = 800
	if mod.IsGoingOnSomeone(bot) then
		local f3 = bot:FindAoELocation(true, true, bot:GetLocation(), 1600, ek, 0, 0)
		local nInRangeEnemy = mod.GetEnemiesNearLoc(f3.targetloc, ek)
		local cr = nil
		for aX, eq in pairs(nInRangeEnemy) do
			if
				mod.IsValidHero(eq)
				and mod.IsInRange(bot, eq, ek)
				and mod.CanCastOnMagicImmune(eq)
				and mod.HasInvisibilityOrItem(eq)
				and not eq:HasModifier("modifier_slardar_amplify_damage")
				and not eq:HasModifier("modifier_item_dustofappearance")
				and not mod.Site.IsLocationHaveTrueSight(eq:GetLocation())
			then
				return BOT_ACTION_DESIRE_HIGH, f3.targetloc, "ground", nil
			end
		end
	end
	local f4 = 0
	for aX, eq in pairs(GetUnitList(UNIT_LIST_ALLIED_HEROES)) do
		if mod.IsValidHero(eq) and not mod.IsSuspiciousIllusion(eq) then
			f4 = f4 + 1
		end
	end
	if mod.IsRoshanAlive() and f4 == 0 then
		if mod.CheckTimeOfDay() == "day" and GetUnitToLocationDistance(bot, mod.Utils.RadiantRoshanLoc) > 1600 then
			return BOT_ACTION_DESIRE_HIGH, mod.Utils.RadiantRoshanLoc, "ground", nil
		end
		if mod.CheckTimeOfDay() == "night" and GetUnitToLocationDistance(bot, mod.Utils.DireRoshanLoc) > 1600 then
			return BOT_ACTION_DESIRE_HIGH, mod.Utils.DireRoshanLoc, "ground", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_demonicon"] = function(bm)
	local bv = 750
	local bx = mod.GetNearbyHeroes(bot, bv, true, BOT_MODE_NONE)
	if mod.IsPushing(bot) then
		local eU = bot:GetNearbyTowers(900, true)
		local f5 = bot:GetNearbyLaneCreeps(900, false)
		if eU ~= nil and #eU >= 1 and f5 ~= nil and #f5 >= 3 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsValidTarget(be) and mod.IsInRange(bot, be, 1000) and not be:HasModifier("modifier_abaddon_borrowed_time") then
		local eM = mod.GetNearbyHeroes(be, 1000, false, BOT_MODE_NONE)
		if eM ~= nil then
			if #eM == 0 then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
			if #eM >= 1 then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_force_field"] = function(bm)
	local ek = 1200
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), ek)
	for aX, eq in pairs(nInRangeEnemy) do
		if
			mod.IsValidHero(eq)
			and eq:GetAttackTarget() == bot
			and (bot:WasRecentlyDamagedByHero(eq, 5) or mod.IsAttackProjectileIncoming(bot, 500))
			and not mod.IsSuspiciousIllusion(eq)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_pirate_hat"] = function(bm)
	return abilityItemUsage.ConsiderItemDesire["item_trusty_shovel"](bm)
end
abilityItemUsage.ConsiderItemDesire["item_mana_draught"] = function(bm)
	local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
	if
		#nEnemyHeroes == 0
		or mod.IsValidHero(nEnemyHeroes[1])
			and not mod.IsInRange(bot, nEnemyHeroes[1], 800)
			and not bot:WasRecentlyDamagedByAnyHero(5.0)
	then
		if mod.GetMP(bot) < 0.5 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_polliwog_charm"] = function(bm)
	local bv = 1000
	if bot:GetMana() < 75 + 40 then
		return BOT_ACTION_DESIRE_NONE
	end
	local nAllyHeroes = mod.GetAlliesNearLoc(bot:GetLocation(), bv)
	local c0 = nil
	local c1 = 99999
	for aX, eE in pairs(nAllyHeroes) do
		if
			mod.IsValidHero(eE)
			and not eE:IsIllusion()
			and not eE:HasModifier("modifier_abaddon_borrowed_time")
			and not eE:HasModifier("modifier_necrolyte_reapers_scythe")
			and not eE:HasModifier("modifier_filler_heal")
			and not eE:HasModifier("modifier_elixer_healing")
			and not eE:HasModifier("modifier_flask_healing")
			and not eE:HasModifier("modifier_juggernaut_healing_ward_heal")
			and not eE:HasModifier("modifier_juggernaut_healing_ward_heal")
			and not eE:IsChanneling()
			and eE:GetMaxHealth() - eE:GetHealth() > 100
		then
			if eE:GetHealth() < c1 then
				c0 = eE
				c1 = eE:GetHealth()
			end
		end
	end
	if c0 ~= nil then
		return BOT_ACTION_DESIRE_HIGH, c0, "unit", nil
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_rippers_lash"] = function(bm)
	local bv = 700
	local ek = 200
	local nAllyHeroes = mod.GetAlliesNearLoc(bot:GetLocation(), bv)
	for aX, eE in pairs(nAllyHeroes) do
		if mod.IsValidHero(eE) and not eE:IsIllusion() then
			local ci = eE:GetAttackTarget()
			if mod.IsGoingOnSomeone(eE) and mod.IsAttacking(eE) then
				if
					mod.IsValidHero(ci)
					and mod.CanBeAttacked(ci)
					and mod.IsInRange(eE, ci, eE:GetAttackRange() + 50)
					and mod.IsInRange(bot, ci, bv)
					and not mod.IsSuspiciousIllusion(ci)
					and not ci:HasModifier("modifier_abaddon_borrowed_time")
					and not ci:HasModifier("modifier_necrolyte_reapers_scythe")
					and not ci:HasModifier("modifier_dazzle_shallow_grave")
				then
					local f3 = bot:FindAoELocation(true, true, ci:GetLocation(), 0, ek, 0, 0)
					if f3.count >= 2 then
						return BOT_ACTION_DESIRE_HIGH, f3.targetloc, "point", nil
					else
						return BOT_ACTION_DESIRE_HIGH, ci:GetLocation(), "point", nil
					end
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_gale_guard"] = function(bm)
	local nAllyHeroes = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE)
	local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
	if bot:HasModifier("modifier_abaddon_aphotic_shield") or not mod.CanBeAttacked(bot) then
		return BOT_ACTION_DESIRE_NONE
	end
	if bot:IsRooted() and #nEnemyHeroes > 0 then
		return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.IsInRange(bot, be, bot:GetAttackRange() + 300)
			and (mod.GetHP(bot) < 0.65 and bot:WasRecentlyDamagedByAnyHero(3.0))
			and not mod.IsSuspiciousIllusion(be)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsRetreating(bot) and not mod.IsRealInvisible(bot) then
		for aX, eq in pairs(nEnemyHeroes) do
			if
				mod.IsValidHero(eq)
				and mod.IsInRange(bot, eq, 800)
				and mod.IsChasingTarget(eq, bot)
				and not mod.IsSuspiciousIllusion(eq)
			then
				if #nEnemyHeroes > #nAllyHeroes or mod.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(3.0) then
					return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
				end
			end
		end
	end
	if mod.IsFarming(bot) then
		local cL = bot:GetNearbyCreeps(1600, true)
		if cL then
			if mod.IsValid(cL[1]) and mod.CanBeAttacked(cL[1]) and mod.GetHP(bot) < 0.25 and mod.IsAttacking(bot) then
				return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
			end
		end
	end
	if mod.IsDoingRoshan(bot) then
		if
			mod.IsRoshan(be)
			and mod.CanBeAttacked(be)
			and mod.IsInRange(bot, be, 500)
			and mod.IsAttacking(bot)
			and mod.GetHP(bot) < 0.5
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if mod.IsDoingTormentor(bot) then
		if mod.IsTormentor(be) and mod.IsInRange(bot, be, 400) and mod.IsAttacking(bot) and mod.GetHP(bot) < 0.5 then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_crippling_crossbow"] = function(bm)
	local bv = mod.GetProperCastRange(false, bot, bm:GetCastRange())
	local bZ = bm:GetSpecialValueInt("damage")
	local nAllyHeroes = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE)
	local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
	for aX, eq in pairs(nEnemyHeroes) do
		if
			mod.IsValidHero(eq)
			and mod.IsInRange(bot, eq, bv)
			and not mod.IsInRange(bot, eq, bv / 2)
			and mod.CanCastOnNonMagicImmune(eq)
			and mod.CanCastOnTargetAdvanced(eq)
		then
			if
				mod.CanKillTarget(eq, bZ, DAMAGE_TYPE_MAGICAL)
				and not eq:HasModifier("modifier_abaddon_borrowed_time")
				and not eq:HasModifier("modifier_dazzle_shallow_grave")
				and not eq:HasModifier("modifier_necrolyte_reapers_scythe")
				and not eq:HasModifier("modifier_oracle_false_promise_timer")
			then
				return BOT_ACTION_DESIRE_HIGH, eq, "unit", nil
			end
		end
	end
	if mod.IsGoingOnSomeone(bot) then
		if
			mod.IsValidHero(be)
			and mod.CanBeAttacked(be)
			and mod.CanCastOnNonMagicImmune(be)
			and mod.CanCastOnTargetAdvanced(be)
			and mod.IsInRange(bot, be, bv)
			and not mod.IsInRange(bot, be, bv / 2)
			and mod.IsChasingTarget(bot, be)
		then
			return BOT_ACTION_DESIRE_HIGH, be, "unit", nil
		end
	end
	if mod.IsRetreating(bot) and not mod.IsRealInvisible(bot) then
		for aX, eq in pairs(nEnemyHeroes) do
			if
				mod.IsValidHero(eq)
				and mod.IsInRange(bot, eq, bv)
				and mod.CanCastOnNonMagicImmune(eq)
				and mod.CanCastOnTargetAdvanced(eq)
				and mod.IsChasingTarget(eq, bot)
				and not mod.IsDisabled(eq)
			then
				if #nEnemyHeroes > #nAllyHeroes or mod.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(3.0) then
					return BOT_ACTION_DESIRE_HIGH, eq, "unit", nil
				end
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_pyrrhic_cloak"] = function(bm)
	local bv = mod.GetProperCastRange(false, bot, bm:GetCastRange())
	local nEnemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
	if
		mod.IsNotAttackProjectileIncoming(bot, 400)
		and mod.IsValidHero(nEnemyHeroes[1])
		and mod.IsInRange(bot, nEnemyHeroes[1], bv)
		and mod.CanCastOnNonMagicImmune(nEnemyHeroes[1])
		and mod.CanCastOnTargetAdvanced(nEnemyHeroes[1])
	then
		return BOT_ACTION_DESIRE_HIGH, nEnemyHeroes[1], "unit", nil
	end
	for aX, eq in pairs(nEnemyHeroes) do
		if
			mod.IsValidHero(eq)
			and mod.IsInRange(bot, eq, bv)
			and mod.CanCastOnNonMagicImmune(eq)
			and mod.CanCastOnTargetAdvanced(eq)
			and eq:GetAttackTarget() == bot
			and (bot:WasRecentlyDamagedByHero(eq, 3.0) or mod.IsAttackProjectileIncoming(bot, 1000))
		then
			return BOT_ACTION_DESIRE_HIGH, eq, "unit", nil
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_minotaur_horn"] = function(bm)
	if
		bot:IsMagicImmune()
		or not mod.CanBeAttacked(bot)
		or not bot:HasModifier("modifier_item_lotus_orb_active")
		or not bot:HasModifier("modifier_antimage_spell_shield")
	then
		return BOT_ACTION_DESIRE_NONE
	end
	local nEnemyHeroes = mod.GetEnemiesNearLoc(bot:GetLocation(), 1200)
	if (mod.IsGoingOnSomeone(bot) or mod.IsRetreating(bot) and not mod.IsRealInvisible(bot)) and #nEnemyHeroes > 0 then
		if bot:IsRooted() then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
		nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 600)
		if bot:IsSilenced() and #nInRangeEnemy >= 2 and not bot:HasModifier("modifier_item_mask_of_madness_berserk") then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
		if
			mod.IsNotAttackProjectileIncoming(bot, 300)
			or mod.IsWillBeCastUnitTargetSpell(bot, 300)
			or mod.IsWillBeCastPointSpell(bot, 300)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
		nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 1200)
		if
			#nInRangeEnemy > #nAllyHeroes
			and mod.GetHP(bot) < 0.6
			and mod.IsValidHero(nInRangeEnemy[1])
			and (mod.IsChasingTarget(nInRangeEnemy[1], bot) or nInRangeEnemy[1]:GetAttackTarget() == bot)
		then
			return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
		end
	end
	if
		bot:HasModifier("modifier_jakiro_macropyre_burn")
		or bot:HasModifier("modifier_lich_chainfrost_slow")
		or bot:HasModifier("modifier_crystal_maiden_freezing_field_slow")
		or bot:HasModifier("modifier_puck_coiled")
		or bot:HasModifier("modifier_skywrath_mystic_flare_aura_effect")
		or bot:HasModifier("modifier_snapfire_magma_burn_slow")
		or bot:HasModifier("modifier_sand_king_epicenter_slow")
	then
		return BOT_ACTION_DESIRE_HIGH, bot, "none", nil
	end
	return BOT_ACTION_DESIRE_NONE
end
abilityItemUsage.ConsiderItemDesire["item_book_of_shadows"] = function(bm)
	local bv = 700 + b8
	local bE = mod.GetAlliesNearLoc(bot:GetLocation(), bv)
	local nInRangeEnemy = mod.GetEnemiesNearLoc(bot:GetLocation(), 1200)
	for aX, eE in pairs(bE) do
		if mod.IsValidHero(eE) and mod.CanCastOnNonMagicImmune(eE) and eE:WasRecentlyDamagedByAnyHero(3) then
			local eQ = mod.GetNearbyHeroes(eE, 1200, true, BOT_MODE_NONE)
			if
				eQ ~= nil
				and #eQ >= 1
				and mod.IsRetreating(eE)
				and not mod.IsRealInvisible(eE)
				and not mod.IsDisabled(eE)
				and eE:DistanceFromFountain() > 1200
			then
				return BOT_ACTION_DESIRE_HIGH, eE, "unit", nil
			end
		end
	end
	return BOT_ACTION_DESIRE_NONE
end
function abilityItemUsage.IsTargetedByEnemy(val51)
	local f6 = GetUnitList(UNIT_LIST_ENEMY_HEROES)
	for aX, f7 in pairs(f6) do
		if mod.IsValidHero(f7) then
			if GetUnitToUnitDistance(val51, f7) <= f7:GetAttackRange() + 200 and f7:GetAttackTarget() == val51 then
				return true
			end
		end
	end
	return false
end
local function f8()
	if
		GetGlyphCooldown() > 0
		or DotaTime() < 60
		or bot ~= GetTeamMember(1)
		or not GetTeamMember(2):IsBot()
		or not GetTeamMember(3):IsBot()
		or not GetTeamMember(4):IsBot()
		or not GetTeamMember(5):IsBot()
	then
		return
	end
	local f9 = {
		TOWER_TOP_1,
		TOWER_MID_1,
		TOWER_BOT_1,
		TOWER_TOP_2,
		TOWER_MID_2,
		TOWER_BOT_2,
		TOWER_TOP_3,
		TOWER_MID_3,
		TOWER_BOT_3,
		TOWER_BASE_1,
		TOWER_BASE_2,
	}
	for aX, fa in pairs(f9) do
		local aU = GetTower(team, fa)
		if
			aU ~= nil
			and aU:GetHealth() > 0
			and aU:GetHealth() / aU:GetMaxHealth() < 0.36
			and aU:CanBeSeen()
			and abilityItemUsage.IsTargetedByEnemy(aU)
		then
			bot:ActionImmediate_Glyph()
			return
		end
	end
	local fb = { BARRACKS_TOP_MELEE, BARRACKS_MID_MELEE, BARRACKS_BOT_MELEE }
	for aX, fc in pairs(fb) do
		local fd = GetBarracks(team, fc)
		if
			fd ~= nil
			and fd:GetHealth() > 0
			and fd:GetHealth() / fd:GetMaxHealth() < 0.5
			and abilityItemUsage.IsTargetedByEnemy(fd)
		then
			bot:ActionImmediate_Glyph()
			return
		end
	end
	local fe = GetAncient(team)
	if fe ~= nil and fe:GetHealth() > 0 and fe:GetHealth() / fe:GetMaxHealth() < 0.5 and abilityItemUsage.IsTargetedByEnemy(fe) then
		bot:ActionImmediate_Glyph()
		return
	end
end
-- Main entry: decide and use_items every frame (called by the bot brain's item-usage stage).
function ItemUsageThink()
	if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(unitName, "hero") or bot:IsIllusion() then
		return
	end
	if not mod.IsNoItemIllution(bot) then
		bg()
	end
	if loadedScript ~= nil and not mod.IsNoAbilityIllution(bot) then
		local ok4, ff = pcall(loadedScript.SkillsComplement)
		if not ok4 then
			log("[ERROR] %s SkillsComplement: %s", unitName, tostring(ff))
		end
	end
	if result and not bot:IsChanneling() then
		local fg = result.ShouldMantaDodge(bot)
		if fg >= 0 then
			local bm = bot:GetItemInSlot(fg)
			if bm then
				bot:Action_UseAbility(bm)
				return
			end
		end
		local fh = result.ShouldUseSelfDispelItem(bot)
		if fh >= 0 then
			local bm = bot:GetItemInSlot(fh)
			if bm then
				bot:Action_UseAbility(bm)
				return
			end
		end
		local fi, d9 = result.ShouldUseAllyDispelItem(bot)
		if fi >= 0 and d9 then
			local bm = bot:GetItemInSlot(fi)
			if bm then
				bot:Action_UseAbilityOnEntity(bm, d9)
				return
			end
		end
	end
	for fj = 6, 8 do
		local fk = bot:GetItemInSlot(fj)
		if fk ~= nil then
			local fl = fk:GetName()
			if fl == "item_famango" or fl == "item_great_famango" or fl == "item_greater_famango" then
				for fm = 0, 5 do
					if bot:GetItemInSlot(fm) == nil then
						bot:ActionImmediate_SwapItems(fj, fm)
						break
					end
				end
				break
			end
		end
	end
end
-- Main entry: decide and cast abilities every frame (called by the bot brain's ability-usage stage).
function AbilityUsageThink()
	HandleIdleBotState(bot)
end
local fn = false
local fo = nil
local fp = 0
local fq = false
local fr = nil
local fs = 0
local ft = nil
local function fu(fv)
	if ft == nil then
		local ok5, bD = pcall(require, GetScriptDirectory() .. "/FuncLib/systems/localization")
		ft = ok5 and bD or false
	end
	if ft and ft.Get then
		local fw = ft.Get(fv)
		if fw and type(fw) == "table" and #fw > 0 then
			return fw[RandomInt(1, #fw)]
		end
		if fw and type(fw) == "string" then
			return fw
		end
	end
	if fv == "say_gg_lose" then
		local fx = { "gg", "ggwp", "GG" }
		return fx[RandomInt(1, #fx)]
	end
	local fx = { "ez", "gg ez", "EZ" }
	return fx[RandomInt(1, #fx)]
end
-- Main entry: decide whether to buy back after death (called by the bot brain's buyback stage).
function BuybackUsageThink()
	if reloadHeroScript2() then
		return
	end
	if bot.lastBuybackFrameProcessTime == nil then
		bot.lastBuybackFrameProcessTime = DotaTime()
	end
	if DotaTime() > 30 and DotaTime() - bot.lastBuybackFrameProcessTime < 2 then
		return
	end
	bot.lastBuybackFrameProcessTime = DotaTime()
	if not bot:IsIllusion() then
		aq()
	end
	if not bot:IsIllusion() then
		f8()
	end
	if not fn and not bot:IsIllusion() and DotaTime() > 10 * 60 then
		local ar = GetAncient(GetTeam())
		if ar ~= nil and mod.GetHP(ar) < 0.2 and mod.CanBeAttacked(ar) then
			local fy = mod.GetNumOfAliveHeroes(false)
			if fy <= 2 then
				if fo == nil then
					fo = RandomInt(1, 5) <= 3
					fp = DotaTime() + RandomFloat(1, 5)
				end
				if fo and DotaTime() >= fp then
					bot:ActionImmediate_Chat(fu("say_gg_lose"), true)
					fn = true
				end
			end
		end
	end
	if not fq and not bot:IsIllusion() and DotaTime() > 10 * 60 then
		local fz = GetAncient(GetOpposingTeam())
		if fz ~= nil and mod.GetHP(fz) < 0.2 and mod.CanBeAttacked(fz) then
			local fy = mod.GetNumOfAliveHeroes(false)
			if fy >= 3 then
				if fr == nil then
					fr = RandomInt(1, 5) <= 3
					fs = DotaTime() + RandomFloat(1, 5)
				end
				if fr and DotaTime() >= fs then
					bot:ActionImmediate_Chat(fu("say_gg_win"), true)
					fq = true
				end
			end
		end
	end
end
-- Main entry: manage the courier (shopping/stash delivery) for this bot.
function CourierUsageThink()
	if reloadHeroScript2() then
		return
	end
	if bot.lastCourierFrameProcessTime == nil then
		bot.lastCourierFrameProcessTime = DotaTime()
	end
	if DotaTime() > 30 and DotaTime() - bot.lastCourierFrameProcessTime < 0.5 then
		return
	end
	bot.lastCourierFrameProcessTime = DotaTime()
	if not bot:IsIllusion() then
		aD()
	end
end
function AbilityLevelUpThink()
	if reloadHeroScript2() then
		return
	end
	if bot.lastLevelUpFrameProcessTime == nil then
		bot.lastLevelUpFrameProcessTime = DotaTime()
	end
	if DotaTime() > 30 and DotaTime() - bot.lastLevelUpFrameProcessTime < 1 then
		return
	end
	bot.lastLevelUpFrameProcessTime = DotaTime()
	if not bot:IsIllusion() then
		handleHeroSwap()
	end
end
function abilityItemUsage.SetAbilityItemList(fA, fB, fC)
	defaultAbility = fA
	defaultItem = fB
	skillList = fC
end
-- Register the public API consumed by the bot brain for this hero, then return the module table.
abilityItemUsage.AbilityLevelUpThink = AbilityLevelUpThink
abilityItemUsage.BuybackUsageThink = BuybackUsageThink
abilityItemUsage.AbilityUsageThink = AbilityUsageThink
abilityItemUsage.ItemUsageThink = ItemUsageThink
return abilityItemUsage
