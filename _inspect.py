from luaparser import ast as L
from luaparser.ast import Node
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
    return res
def show(node, d=0):
    n = type(node).__name__
    extra = ""
    if n == "Name": extra = " id=%r" % getattr(node,"id",None)
    if n == "LocalAssign": extra = " targets=%r" % [getattr(t,"id",None) for t in getattr(node,"targets",[])]
    if n == "Function": extra = " name=%r args=%r" % (getattr(node,"name",None) and getattr(node.name,"id",None), [getattr(a,"id",None) for a in getattr(node,"args",[])])
    print("  "*d + n + extra)
    for c in children(node): show(c, d+1)
show(L.parse('local function u(v) local y = 1 end\nfunction g(w) end\n'))
