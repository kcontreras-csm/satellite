#!/usr/bin/python3
"""Offline app-server fixture: synthetic failures only, no account or network access."""
import json, sys

def emit(value): print(json.dumps(value), flush=True)
def reply(ident, result): emit({'id':ident,'result':result})
def event(method, params): emit({'method':method,'params':params})
counter = 0
interrupted = 0
turns = {}
workspace_error = {
    'message':'Reconnecting... 1/5',
    'codexErrorInfo':{'responseStreamDisconnected':{'httpStatusCode':403}},
    'additionalDetails':'unexpected status 403 Forbidden: {"detail":{"message":"Unauthorized: Contact your ChatGPT workspace administrator for access.","code":"codex_workspace_access_denied"}} token=synthetic-secret'
}
for line in sys.stdin:
    value = json.loads(line)
    method, ident, params = value.get('method'), value.get('id'), value.get('params',{})
    if ident is None: continue
    if method == 'initialize': reply(ident, {'userAgent':'offline-test'})
    elif method == 'account/read': reply(ident, {'account':{'type':'chatgpt'}})
    elif method == 'app/installed': reply(ident, {'apps':[{'id':'slack','runtimeName':'Slack','enabled':True,'callable':True}]})
    elif method == 'app/read': reply(ident, {'apps':[{'id':'slack','name':'Slack','toolSummaries':[]}]})
    elif method == 'config/read': reply(ident, {'config':{}})
    elif method == 'thread/start':
        counter += 1
        reply(ident, {'thread':{'id':'thread-'+str(counter)}})
    elif method == 'turn/start':
        tid = params['threadId']; turn = 'turn-'+tid
        scenario = params['input'][0]['text']
        reply(ident, {'turn':{'id':turn,'status':'inProgress'}})
        event('turn/started', {'threadId':tid,'turn':{'id':turn,'status':'inProgress'}})
        if scenario == 'workspace-denied':
            event('error', {'threadId':tid,'turnId':turn,'error':workspace_error,'willRetry':True})
        elif scenario == 'retry-success':
            event('error', {'threadId':tid,'turnId':turn,'error':{'message':'Reconnecting...', 'codexErrorInfo':{'responseStreamDisconnected':{'httpStatusCode':None}}},'willRetry':True})
            research = {'caseId':'500000000000001AAA','caseNumber':'100001','summary':'Synthetic brief'}
            event('item/completed', {'threadId':tid,'item':{'type':'agentMessage','text':json.dumps(research)}})
            event('turn/completed', {'threadId':tid,'turn':{'id':turn,'status':'completed','error':None}})
        elif scenario == 'interrupted':
            event('turn/completed', {'threadId':tid,'turn':{'id':turn,'status':'interrupted','error':None}})
        else:
            error = {'message':'synthetic-secret', 'codexErrorInfo':'usageLimitExceeded'}
            event('turn/completed', {'threadId':tid,'turn':{'id':turn,'status':'failed','error':error}})
    elif method == 'turn/interrupt':
        interrupted += 1
        reply(ident, {})
        event('turn/completed', {'threadId':params['threadId'],'turn':{'id':params['turnId'],'status':'interrupted','error':None}})
    elif method == 'test/stats': reply(ident, {'interrupted':interrupted})
    elif method == 'test/rpc-denied': emit({'id':ident,'error':{'code':-1,**workspace_error}})
    else: reply(ident, {})
