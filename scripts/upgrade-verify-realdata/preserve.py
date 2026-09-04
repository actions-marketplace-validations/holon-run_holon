import json, sys
old, new = (json.load(open(p)) for p in sys.argv[1:3])
result = {
    "agents_lost": [a for a in old["agents"] if a not in new["agents"]],
    "messages_lost": [m for m in old["msg_ids"] if m not in new["msg_ids"]],
}
json.dump(result, sys.stdout)
