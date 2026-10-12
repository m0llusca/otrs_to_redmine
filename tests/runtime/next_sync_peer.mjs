// Controlled Redmine peer for the isolated 1000-ticket sync comparison.
// This process has no upstream access. Control/statistics requests are excluded.
import http from 'node:http';
import {createHash} from 'node:crypto';
let config = {issueIDs: [7001], phase: 'steady'};
let counts = {}, responseBytes = 0, uploaded = [], attached = [], created = null;
let sockets = new Set(), details = 0, failures = 0;
const initialTime = '2026-01-01T00:00:00Z';
const changedTime = '2026-01-02T00:00:00Z';
const statusNames = {1: 'New', 2: 'Проверка решения', 3: 'In Progress'};
const fileBytes = () => config.largeBytes ? Buffer.alloc(config.largeBytes, 82) : Buffer.from([0,255,128,65]);
function issue(id, include = '') {
  const phase = config.phase || 'steady';
  const changed = phase !== 'steady';
  const rapid = phase === 'rapid';
  const override = config.issues?.[id] || {};
  const statusID = override.statusID ?? (rapid ? 1 : changed ? 2 : 1);
  const data = {
    id, tracker: {id: 2, name: 'Task'}, project: {id: 1, name: 'Benchmark'},
    status: {id: statusID, name: override.status || statusNames[statusID]},
    updated_on: override.updatedOn || config.updatedOn || (changed ? changedTime : initialTime),
  };
  if (include.includes('journals')) {
    data.journals = override.journals || (changed ? [{
      id: 11, user: {id:2,name:'Benchmark engineer'}, notes:'Controlled status transition',
      details:[{property:'attr',name:'status_id',old_value:'1',new_value:'2'}],
    }] : []);
    if (rapid && !override.journals) data.journals.push({
      id:12,user:{id:2,name:'Benchmark engineer'},notes:'Controlled return transition',
      details:[{property:'attr',name:'status_id',old_value:'2',new_value:'1'}],
    });
    if (phase === 'later' && !override.journals) data.journals.push({
      id:12,user:{id:2,name:'Benchmark engineer'},notes:'Controlled next generation',
      details:[{property:'attr',name:'status_id',old_value:'1',new_value:'2'}],
    });
  }
  if (include.includes('attachments')) data.attachments = override.attachments ||
    (changed && config.attachments ? [{
      id:1,filename:'fixture.bin',filesize:config.metadataBytes ?? fileBytes().length,
      content_type:'application/octet-stream',content_url:'http://redmine:8080/attachments/download/1',
    }] : []);
  return data;
}
async function body(req) {let data='';for await (const part of req) data+=part;return data;}
const handler = async (req,res) => {
  const url = new URL(req.url,'http://redmine:8080');
  const control = url.pathname.startsWith('/__') || url.pathname === '/health';
  const send = (payload,code=200,headers={}) => {
    const data = Buffer.isBuffer(payload) ? payload : Buffer.from(JSON.stringify(payload));
    if (!control) responseBytes += data.length;
    res.writeHead(code,{'Content-Type':Buffer.isBuffer(payload)?'application/octet-stream':'application/json; charset=utf-8','Content-Length':data.length,...headers});
    res.end(data);
  };
  if (url.pathname === '/__control' && req.method === 'POST') {
    const change=JSON.parse(await body(req));
    config=change.merge?{...config,...change}:change;
    if (change.resetStats !== false) {
      counts={};responseBytes=0;uploaded=[];attached=[];created=null;sockets=new Set();details=0;failures=0;
    }
    return send({ok:true,config});
  }
  if (url.pathname === '/__stats') return send({config,counts,connections:sockets.size,
    open_connections:[...sockets].filter(s=>!s.destroyed).length,response_bytes:responseBytes,
    uploaded_bytes:uploaded.map(x=>x.bytes),uploaded_hashes:uploaded.map(x=>x.sha256),attached,created});
  if (url.pathname === '/health') return send({ok:true});
  const key=`${req.method} ${url.pathname}${url.search}`;
  counts[key]=(counts[key]||0)+1;sockets.add(req.socket);
  if (config.delayMillis) await new Promise(resolve=>setTimeout(resolve,config.delayMillis));
  const quota=config.quota;
  if (quota && (!quota.path || url.pathname.startsWith(quota.path)) && failures < (quota.count ?? 1)) {
    failures++;
    return send({errors:['Controlled temporary failure']},quota.code || 429,
      {'Retry-After':String(quota.retryAfter ?? 2)});
  }
  if (url.pathname.startsWith('/attachments/download/')) {
    if (config.fileError) return send({errors:['Controlled missing attachment']},404);
    return send(fileBytes());
  }
  if (url.pathname === '/issue_statuses.json') return send({issue_statuses:Object.entries(statusNames).map(([id,name])=>({id:Number(id),name}))});
  if (url.pathname === '/issues.json' && req.method === 'GET') {
    let ids=url.searchParams.has('issue_id') ? url.searchParams.get('issue_id').split(',').map(Number) : [...(config.issueIDs || [7001])];
    const known=new Set(config.issueIDs || ids);ids=ids.filter(id=>known.has(id));
    const status=url.searchParams.get('status_id');
    if (status && status !== '*') ids=ids.filter(id=>String(issue(id).status.id)===status);
    ids.sort((a,b)=>a-b);
    const total=ids.length, limit=Math.max(1,Math.min(100,Number(url.searchParams.get('limit'))||25));
    const offset=Math.max(0,Number(url.searchParams.get('offset'))||0);
    return send({issues:ids.slice(offset,offset+limit).map(id=>issue(id,url.searchParams.get('include')||'')),total_count:total,offset,limit});
  }
  if (url.pathname === '/uploads.json') {
    const hash=createHash('sha256');let bytes=0;
    for await(const part of req){bytes+=part.length;hash.update(part);}
    const token=`bench-${uploaded.length+1}`;uploaded.push({token,bytes,sha256:hash.digest('hex')});
    return send({upload:{token}},201);
  }
  if (url.pathname === '/issues.json' && req.method === 'POST') {
    created=JSON.parse(await body(req)).issue;return send({issue:issue(900)},201);
  }
  const hit=url.pathname.match(/^\/issues\/(\d+)\.json$/);
  if (hit) {
    if (req.method === 'PUT') {
      const patch=JSON.parse((await body(req))||'{}').issue || {};
      if(patch.uploads)attached.push(...patch.uploads);
      res.writeHead(204);return res.end();
    }
    const include=url.searchParams.get('include')||'';
    const data=issue(Number(hit[1]),include);
    if(include.includes('journals')) {
      details++;
      if(config.advanceAfterDetails && details===config.advanceAfterDetails) {
        config={...config,...config.advanceTo};
      }
    }
    return send({issue:data});
  }
  if(url.pathname==='/enumerations/issue_priorities.json')return send({issue_priorities:[{id:2,name:'Normal',is_default:true}]});
  if(url.pathname==='/projects/1/memberships.json')return send({memberships:[{user:{id:2,name:'Benchmark agent'}}],total_count:1});
  if(url.pathname==='/projects/1.json')return send({project:{id:1,name:'Benchmark',trackers:[{id:2,name:'Task'}]}});
  if(url.pathname==='/projects.json')return send({projects:[{id:1,name:'Benchmark'}],total_count:1});
  if(url.pathname==='/trackers.json')return send({trackers:[{id:2,name:'Task'}]});
  return send({errors:['Unsupported local fixture endpoint']},404);
};
http.createServer((req,res)=>handler(req,res).catch(error=>{
  console.error(error.message);if(!res.headersSent)res.writeHead(500);res.end();
})).listen(Number(process.env.PORT)||8080,'0.0.0.0');
