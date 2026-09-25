#!/usr/bin/env python3
# Scope-aware de-obfuscator for ability_item_usage_generic.lua
# Renames single-letter LOCAL variables to typed/meaningful names (preserving field/method keys).
import re, sys
from luaparser import ast as L
from luaparser.ast import Node

PATH = "ability_item_usage_generic.lua"
src = open(PATH, encoding="utf-8").read()
N = len(src)

# ---------- hand-rolled NAME lexer (skips strings/comments) ----------
NUM_RE = re.compile(r'^(0[xX][0-9a-fA-F]+|[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?|\.[0-9]+)')
def lex_names(code):
    toks = []
    i = 0; n = len(code)
    while i < n:
        c = code[i]
        if c == '-' and i+1 < n and code[i+1] == '-':
            if i+2 < n and code[i+2] == '[':
                j = code.find(']]', i+2)
                i = n if j == -1 else j+2
            else:
                j = code.find('\n', i)
                i = n if j == -1 else j+1
            continue
        if c == '"' or c == "'":
            q = c; i += 1
            while i < n:
                if code[i] == '\\':
                    i += 2; continue
                if code[i] == q:
                    i += 1; break
                i += 1
            continue
        m = re.match(r'\[(=*)\[', code[i:])
        if m:
            eq = m.group(1); close = ']' + eq + ']'
            j = code.find(close, i + len(m.group(0)))
            i = n if j == -1 else j + len(close)
            continue
        nm = NUM_RE.match(code[i:])
        if nm:
            i += len(nm.group(0)); continue
        if c.isalpha() or c == '_':
            j = i
            while j < n and (code[j].isalnum() or code[j] == '_'):
                j += 1
            toks.append((i, j, code[i:j]))
            i = j
            continue
        i += 1
    return toks

name_tokens = lex_names(src)
# all identifier names (for collision avoidance)
existing_names = set(t[2] for t in name_tokens)
single_letters = set(t[2] for t in name_tokens if len(t[2]) == 1)
for s in single_letters:
    existing_names.add(s)

# ---------- AST helpers ----------
def children(node):
    res = []
    for k in dir(node):
        if k.startswith("_") or k in ("position","fields"): continue
        try: v = getattr(node, k)
        except Exception: continue
        if isinstance(v, Node): res.append(v)
        elif isinstance(v, list):
            for it in v:
                if isinstance(it, Node): res.append(it)
    flds = getattr(node, "fields", None)
    if isinstance(flds, list):
        for it in flds:
            if isinstance(it, Node): res.append(it)
    return res

def node_type(node):
    return type(node).__name__

def span_of(node):
    ft = getattr(node, "first_token", None)
    lt = getattr(node, "last_token", None)
    if ft is not None and lt is not None:
        return (ft.start, lt.stop)
    return None

def str_val(node):
    for a in ("s", "value"):
        if hasattr(node, a):
            v = getattr(node, a)
            if isinstance(v, bytes):
                v = v.decode("utf-8", "ignore")
            if isinstance(v, str):
                return v
    return None

def call_args(node):
    return getattr(node, "args", None) or []

# ---------- scope structures ----------
scopes = []  # each: {start,stop,depth,decls:letter->name}
used_names = set(existing_names)   # globally taken names
name_comments = {}                 # new_name -> comment (for header/inline)
fn_seq = [0]
candidate_tables = []   # root-scope Table locals (module return candidates)
top_returns = []        # root-scope single-letter names returned at top level

def unique_name(base):
    base = re.sub(r'[^A-Za-z0-9_]', '', base)
    if base and base[0].isdigit():
        base = "v" + base
    cand = base or "val"
    if cand not in used_names:
        used_names.add(cand); return cand
    i = 2
    while f"{base}{i}" in used_names:
        i += 1
    used_names.add(f"{base}{i}")
    return f"{base}{i}"

def register(scope, letter, base):
    nm = unique_name(base)
    scope["decls"][letter] = nm
    return nm

# ---------- kind inference ----------
def module_base(s):
    if not s: return "mod"
    s = s.replace("\\", "/")
    parts = [p for p in s.split("/") if p and not p.startswith("GetScriptDirectory")]
    last = parts[-1].replace(".lua", "") if parts else "mod"
    if len(parts) >= 2:
        last = parts[-2] + "_" + last
    # camelCase
    segs = last.split("_")
    return segs[0] + "".join(w.capitalize() for w in segs[1:])

def get_method_id(invoke):
    for attr in ("method", "func"):
        m = getattr(invoke, attr, None)
        if node_type(m) == "Name": return getattr(m, "id", None)
        if node_type(m) == "String": return str_val(m)
    recv = getattr(invoke, "receiver", None)
    recv_id = getattr(recv, "id", None) if node_type(recv) == "Name" else None
    for ch in children(invoke):
        cid = getattr(ch, "id", None)
        if node_type(ch) == "Name" and cid != recv_id and (cid or "")[:1].isupper():
            return cid
    return None

def method_base(mid):
    if mid in ("GetUnitName",): return "unitName"
    if mid in ("GetAbsOrigin","GetOrigin","GetCursorPosition","GetMousePosition"): return "position"
    if mid in ("GetName",): return "nameStr"
    return "val"

def table_base(value):
    sp = span_of(value)
    if sp:
        seg = src[sp[0]:sp[1]]
        if "kez_" in seg: return "kezAbilitySwapMap"
    for ch in children(value):
        if node_type(ch) == "Field":
            key = getattr(ch, "key", None)
            if node_type(key) == "String" and (str_val(key) or "").startswith("kez_"):
                return "kezAbilitySwapMap"
    return "tbl"

def function_base(fn):
    sp = span_of(fn)
    if not sp: return "helper"
    seg = src[sp[0]:sp[1]]
    if "Reload" in seg or "dofile" in seg: return "reloadHeroScript"
    if "ARDM" in seg or "StaleARDMHero" in seg: return "handleHeroSwap"
    if "CastAbility" in seg or "ConsiderCast" in seg: return "castAbility"
    if "UseItem" in seg: return "useItem"
    if "ShouldUse" in seg or "Consider" in seg: return "shouldUse"
    return "helper"

METHOD_KIND = {
    "GetHealth":"unit","GetMaxHealth":"unit","IsAlive":"unit","IsHero":"unit","IsIllusion":"unit",
    "IsInvulnerable":"unit","GetTeam":"unit","GetUnitName":"unit","GetAbsOrigin":"unit",
    "GetOwner":"unit","GetPlayer":"unit","GetLevel":"unit","GetAttackDamage":"unit","GetMana":"unit",
    "GetMaxMana":"unit","GetCurrentMovementSpeed":"unit","GetAttackRange":"unit","GetCastRange":"unit",
    "GetOpposingTeamMembers":"unit","GetNearbyHeroes":"unit","GetNearbyCreeps":"unit","GetNearbyTowers":"unit",
    "GetNearbyUnits":"unit","GetHealthPercent":"unit","GetManaPercent":"unit","GetBaseDamage":"unit",
    "GetHealthDeficit":"unit","GetManaDeficit":"unit","HasModifier":"unit","HasScepter":"unit",
    "GetPrimaryAttribute":"unit","GetStashValue":"unit","GetNetWorth":"unit","IsChanneling":"unit",
    "GetActiveMode":"unit","GetAttackTarget":"unit","GetNumItemsInStash":"unit","IsUsingAbility":"unit",
    "GetAbilityName":"ability","GetAbilityIndex":"ability","GetCooldown":"ability","GetCooldownTimeRemaining":"ability",
    "GetAutoCastState":"ability","GetBehavior":"ability","CanBeCasted":"ability","IsActivated":"ability",
    "GetAbilityDamage":"ability","GetAbilityTargetFlags":"ability","GetToggleState":"ability","GetSpecialValue":"ability",
    "GetSpecialValueFor":"ability","IsHidden":"ability","IsTrained":"ability","IsCooldownReady":"ability",
    "GetHeroLevelRequiredToUpgrade":"ability","CanBeUpgraded":"ability","GetAssociatedPrimaryAbilities":"ability",
    "GetSecondaryAbilities":"ability","IsInAbilityPhase":"ability","GetChannelTime":"ability","GetCastPoint":"ability",
    "GetManaCost":"ability","GetGoldCost":"ability","IsPassive":"ability","GetAbilityTextureName":"ability",
    "GetAbilityReady":"ability","GetCurrentAbilityType":"ability","ShouldUseAbility":"ability",
    "GetItemName":"item","GetCost":"item","GetItemSlot":"item","GetCurrentCharges":"item","GetItemCharges":"item",
    "GetPurchaseCost":"item","CanBeUsed":"item","IsItem":"item","GetPurchaser":"item","GetCastRange":"item",
    "GetItemWanted":"item","GetCostFor":"item","GetSpecialValueFor":"item",
    "GetModifierName":"modifier","GetModifierDuration":"modifier","GetModifierStackCount":"modifier",
    "GetCursorPosition":"position","GetMousePosition":"position","GetCursorWorldPosition":"position",
}

def usage_base(decl_node):
    # scan subtree for Invoke whose receiver is decl_node (compare by id) to infer kind
    target_id = getattr(decl_node, "id", None)
    found = {}
    def walk(node):
        t = node_type(node)
        if t == "Invoke":
            recv = getattr(node, "receiver", None)
            mid = getattr(getattr(node, "method", None), "id", None)
            if isinstance(recv, Node) and getattr(recv, "id", None) == target_id and mid in METHOD_KIND:
                found[METHOD_KIND[mid]] = True
        for ch in children(node):
            walk(ch)
    walk(decl_node)
    for k in ("unit","ability","item","modifier","position"):
        if k in found: return k
    return "val"

def base_for(decl_node, value, for_kind):
    if value is not None:
        t = node_type(value)
        if t == "Call":
            callee = getattr(value, "func", None)
            if node_type(callee) == "Name":
                cid = getattr(callee, "id", None)
                if cid == "GetBot": return "bot"
                if cid == "GetTeam": return "team"
                if cid == "require": return module_base(str_val(call_args(value)[0]) if call_args(value) else None)
                if cid == "dofile":
                    a0 = str_val(call_args(value)[0]) if call_args(value) else None
                    return "heroScript" if (a0 and "BotsLib" in a0) else "loadedScript"
                if cid == "Vector":
                    spv = span_of(value)
                    seg = src[spv[0]:spv[1]] if spv else ""
                    import re as _re
                    m = _re.search(r'Vector\(\s*(-?\d+)', seg)
                    if m and int(m.group(1)) < 0:
                        return "radiantBase"
                    return "direBase"
                return "val"
            if node_type(callee) == "Invoke":
                return method_base(getattr(getattr(callee, "method", None), "id", None))
        if t == "Invoke":
            return method_base(get_method_id(value))
        if "Table" in t: return table_base(value)
        if t == "String": return "text"
        if t in ("Number","BinaryOp","UnaryOp","Concat"): return "value"
        # constant `10 == 10` idiom means "always true"
        if t == "BinaryOp" and node_type(value) == "BinaryOp":
            seg = src[span_of(value)[0]:span_of(value)[1]] if span_of(value) else ""
            if "==" in seg and seg.split("==")[0].strip().lstrip("(").isdigit() and seg.split("==")[1].strip().rstrip(")").isdigit():
                return "alwaysTrue"
        if t in ("TrueExpr","FalseExpr","NilExpr"): return "flag"
        if "Function" in t: return function_base(value)
        if t == "Index":
            idx = getattr(value, "idx", None)
            if node_type(idx) == "String":
                key = str_val(idx)
                if key == "sSkillList": return "skillList"
                if key == "bDeafaultAbility": return "defaultAbility"
                if key == "bDeafaultItem": return "defaultItem"
    if for_kind == "fornum": return "i"
    if for_kind == "forin": return "loopVar"
    return usage_base(decl_node)

# ---------- scope walk ----------
def walk(node, scope, top_level=False):
    t = node_type(node)
    if t in ("Function","AnonymousFunction","LocalFunction"):
        sp = span_of(node)
        ns = None
        if sp:
            ns = {"start":sp[0],"stop":sp[1],"depth":scope["depth"]+1,"decls":{}}
            scopes.append(ns)
        # register function name (local for LocalFunction; global def -> root so call sites resolve)
        nm = getattr(node, "name", None)
        if node_type(nm) == "Name" and len(getattr(nm,"id","")) == 1:
            fid = getattr(nm,"id")
            if t == "LocalFunction":
                register(scope, fid, function_base(node))
            else:
                if fid not in scopes[0]["decls"]:
                    scopes[0]["decls"][fid] = unique_name(function_base(node))
        for arg in getattr(node, "args", []) or []:
            if node_type(arg) == "Name" and len(getattr(arg,"id","")) == 1:
                register(ns if ns else scope, getattr(arg,"id"), base_for(arg, None, None))
        walk(getattr(node,"body",None), ns if ns else scope)
        return
    if t == "Fornum":
        sp = span_of(node)
        if sp:
            ns = {"start":sp[0],"stop":sp[1],"depth":scope["depth"]+1,"decls":{}}
            scopes.append(ns)
            tg = getattr(node,"target",None)
            if node_type(tg) == "Name" and len(getattr(tg,"id",""))==1:
                register(ns, getattr(tg,"id"), base_for(tg, None, "fornum"))
            for x in (getattr(node,"start",None), getattr(node,"stop",None), getattr(node,"step",None)):
                walk(x, scope)
            walk(getattr(node,"body",None), ns)
            return
        else:
            for x in (getattr(node,"start",None), getattr(node,"stop",None), getattr(node,"step",None)):
                walk(x, scope)
            walk(getattr(node,"body",None), scope); return
    if t == "Forin":
        sp = span_of(node)
        if sp:
            ns = {"start":sp[0],"stop":sp[1],"depth":scope["depth"]+1,"decls":{}}
            scopes.append(ns)
            for tg in getattr(node,"targets",[]) or []:
                if node_type(tg) == "Name" and len(getattr(tg,"id",""))==1:
                    register(ns, getattr(tg,"id"), base_for(tg, None, "forin"))
            walk(getattr(node,"iter",None), scope)
            walk(getattr(node,"body",None), ns)
            return
        else:
            walk(getattr(node,"iter",None), scope)
            walk(getattr(node,"body",None), scope); return
    if t == "Do":
        sp = span_of(node)
        if sp:
            ns = {"start":sp[0],"stop":sp[1],"depth":scope["depth"]+1,"decls":{}}
            scopes.append(ns); walk(getattr(node,"body",None), ns); return
        else:
            walk(getattr(node,"body",None), scope); return
    if t == "While":
        walk(getattr(node,"test",None), scope)
        sp = span_of(node)
        if sp:
            ns = {"start":sp[0],"stop":sp[1],"depth":scope["depth"]+1,"decls":{}}
            scopes.append(ns); walk(getattr(node,"body",None), ns)
        else:
            walk(getattr(node,"body",None), scope)
        return
    if t in ("If","ElseIf"):
        walk(getattr(node,"test",None), scope)
        sp = span_of(node)
        ns = None
        if sp:
            ns = {"start":sp[0],"stop":sp[1],"depth":scope["depth"]+1,"decls":{}}
            scopes.append(ns)
        walk(getattr(node,"body",None), ns if ns else scope)
        orelse = getattr(node,"orelse",None)
        if orelse is not None:
            if node_type(orelse) in ("If","ElseIf"):
                walk(orelse, scope)
            else:
                walk(orelse, ns if ns else scope)
        return
    if t == "Repeat":
        sp = span_of(node)
        ns = None
        if sp:
            ns = {"start":sp[0],"stop":sp[1],"depth":scope["depth"]+1,"decls":{}}
            scopes.append(ns)
        walk(getattr(node,"body",None), ns if ns else scope)
        walk(getattr(node,"test",None), ns if ns else scope)
        return
    if t == "LocalAssign":
        targets = getattr(node,"targets",[]) or []
        values = getattr(node,"values",[]) or []
        handled = set()
        # module return table candidate: root-scope `local x = {...}`
        if scope["depth"] == 0:
            for idx, tg in enumerate(targets):
                if node_type(tg) == "Name" and len(getattr(tg,"id",""))==1:
                    val = values[idx] if idx < len(values) else None
                    if val is not None and "Table" in node_type(val):
                        candidate_tables.append(getattr(tg,"id"))
        # special: pcall -> two results
        if values and node_type(values[0]) == "Call" and getattr(getattr(values[0],"func",None),"id",None) == "pcall":
            a0 = call_args(values[0])[0] if call_args(values[0]) else None
            is_dispel = (node_type(a0)=="Call" and getattr(getattr(a0,"func",None),"id",None)=="require" and str_val(call_args(a0)[0] or None) and "dispel" in (str_val(call_args(a0)[0]) or ""))
            for idx, tg in enumerate(targets):
                if node_type(tg) == "Name" and len(getattr(tg,"id",""))==1:
                    base = ("dispelOk" if idx==0 else "dispelModule") if is_dispel else ("ok" if idx==0 else "result")
                    register(scope, getattr(tg,"id"), base); handled.add(getattr(tg,"id"))
        else:
            for idx, tg in enumerate(targets):
                if node_type(tg) == "Name" and len(getattr(tg,"id",""))==1 and getattr(tg,"id") not in handled:
                    val = values[idx] if idx < len(values) else None
                    register(scope, getattr(tg,"id"), base_for(tg, val, None))
        for v in values:
            walk(v, scope)
        return
    if t == "Return":
        if scope["depth"] == 0:
            for v in getattr(node,"values",[]) or []:
                if node_type(v) == "Name" and len(getattr(v,"id",""))==1:
                    top_returns.append(getattr(v,"id"))
        walk_children(node, scope); return
    if t in ("Chunk","Block"):
        walk_children(node, scope); return
    walk_children(node, scope)

def walk_children(node, scope):
    for ch in children(node):
        walk(ch, scope)

# collect goto/labels etc are skipped (Name in Label/Goto handled as refs; safe)
tree = L.parse(src)
root = {"start":0,"stop":N,"depth":0,"decls":{}}
scopes.append(root)
walk(tree, root)
print("scopes:", len(scopes), "root decls:", len(root["decls"]))

# module return table: prefer a root Table local returned at top level
mod_target = None
for c in top_returns:
    if c in candidate_tables:
        mod_target = c; break
if mod_target is None and candidate_tables:
    mod_target = candidate_tables[0]
if mod_target is not None and mod_target in scopes[0]["decls"]:
    scopes[0]["decls"][mod_target] = unique_name("abilityItemUsage")

# also map field/method keys globally? We SKIP them via '.'/':' heuristic, so nothing to do.

# ---------- apply renames ----------
# For each single-letter NAME token, decide rename
edits = []  # (start, end, newname)
for (s, e, text) in name_tokens:
    if len(text) != 1:
        continue
    # field/method key if preceded by '.' (single, not '..' concat or decimal) or ':' (method)
    k = s - 1
    while k >= 0 and src[k] in " \t\r\n":
        k -= 1
    if k >= 0:
        c0 = src[k]
        if c0 == ":":
            continue  # method/field key after ':'
        if c0 == ".":
            if k - 1 >= 0 and (src[k-1] == "." or src[k-1].isdigit()):
                pass  # '..' concat or decimal point -> variable, rename it
            else:
                continue  # field key after single '.'
    # resolve via tightest enclosing scope that declares this letter (robust to sibling branches at same depth)
    containing = [sc for sc in scopes if sc["start"] <= s < sc["stop"]]
    containing.sort(key=lambda sc: (sc["stop"] - sc["start"]))
    new = None
    for sc in containing:
        if text in sc["decls"]:
            new = sc["decls"][text]
            break
    if new is not None:
        edits.append((s, e, new))

# sort descending and apply
edits.sort(key=lambda x: x[0], reverse=True)
out = src
for (s, e, new) in edits:
    out = out[:s] + new + out[e:]

# verify
try:
    L.parse(out)
    print("REPARSE OK, edits:", len(edits))
except Exception as ex:
    print("REPARSE FAIL:", repr(ex))
    sys.exit(1)

# count remaining single-letter NAME tokens (should be only field/method keys)
rem = [t for t in lex_names(out) if len(t[2]) == 1]
print("remaining single-letter tokens:", len(rem))

open(PATH, "w", encoding="utf-8").write(out)
print("written", PATH)
