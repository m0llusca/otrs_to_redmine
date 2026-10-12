import http from 'node:http';
import https from 'node:https';
import {existsSync,readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
let scenario = 'unchanged';
let counts = {};
let created = null;
let uploads = [];
let attached = [];
let verifyUploads = false;
let dataConnections = new Set();
const changed = () => scenario === 'inbound' || scenario === 'binary';
const fileCount = () => scenario === 'binary' ? 1 : 2;
const fileBytes = () => scenario === 'binary' ? Buffer.from([0, 255, 128, 65]) : Buffer.alloc(1024 * 1024, 82);
function issue(id, include) {
  const data = {
    id, tracker: {id: 2, name: 'Task'}, project: {id: 1, name: 'Benchmark'},
    status: {name: changed() ? 'Проверка решения' : 'New'},
    updated_on: changed() ? '2026-01-02T00:00:00Z' : '2026-01-01T00:00:00Z',
  };
  if (include.includes('journals')) data.journals = changed() ? [{
    id: 11, user: {id: 2, name: 'Benchmark engineer'}, notes: 'Controlled status transition',
    details: [{property: 'attr', name: 'status_id', old_value: '1', new_value: '2'}],
  }] : [];
  if (include.includes('attachments')) data.attachments = changed()
    ? Array.from({length: fileCount()}, (_, i) => ({
        id: i + 1, filename: `fixture-${i+1}.bin`, filesize: fileBytes().length,
        content_type: 'application/octet-stream', content_url: `http://redmine:8080/attachments/download/${i+1}`,
      })) : [];
  return data;
}
const handleRequest = async (req, res) => {
  const url = new URL(req.url, 'http://redmine:8080');
  const key = `${req.method} ${url.pathname}${url.search}`;
  const json = (data, code=200) => {res.writeHead(code, {'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(data));};
  if (url.pathname === '/__control') {
    let body='';for await (const part of req) body+=part;
    const control=JSON.parse(body);
    scenario=control.scenario;verifyUploads=Boolean(control.verifyUploads);counts={};created=null;uploads=[];attached=[];dataConnections=new Set();return json({ok:true});
  }
  if (url.pathname === '/__stats') return json({scenario, counts, data_connections:dataConnections.size, open_data_connections:[...dataConnections].filter(s=>!s.destroyed).length, uploaded_bytes: uploads.map(u=>u.bytes), uploaded_hashes: uploads.map(u=>u.sha256), attached, created});
  if (url.pathname === '/health') return json({ok:true});
  counts[key]=(counts[key] || 0)+1;
  dataConnections.add(req.socket);
  if (url.pathname.startsWith('/attachments/download/')) {
    const bytes=fileBytes();res.writeHead(200, {'Content-Type':'application/octet-stream','Content-Length':bytes.length});return res.end(bytes);
  }
  if (url.pathname === '/uploads.json') {
    let bytes=0;const hash=verifyUploads?createHash('sha256'):null;
    for await (const part of req) {bytes+=part.length;if(hash)hash.update(part);}
    const token=`bench-${uploads.length+1}`;uploads.push({token,bytes,sha256:hash?hash.digest('hex'):null});return json({upload:{token}},201);
  }
  if (url.pathname === '/issues.json' && req.method === 'POST') {
    let body='';for await (const part of req) body+=part;
    created=JSON.parse(body).issue;return json({issue: issue(900,[])},201);
  }
  const hit=url.pathname.match(/^\/issues\/(\d+)\.json$/);
  if (hit) {
    if(req.method === 'PUT') {
      let body='';for await (const part of req)body+=part;
      const patch=body?JSON.parse(body).issue:{};
      if(patch.uploads)attached.push(...patch.uploads);
      res.writeHead(204);return res.end();
    }
    return json({issue: issue(Number(hit[1]), (url.searchParams.get('include') || '').split(','))});
  }
  if(url.pathname === '/enumerations/issue_priorities.json') return json({issue_priorities:[{id:2,name:'Normal',is_default:true}]});
  if(url.pathname === '/projects/1/memberships.json') return json({memberships:[{user:{id:2,name:'Benchmark agent'}}],total_count:1});
  if(url.pathname === '/projects/1.json') return json({project:{id:1,name:'Benchmark',trackers:[{id:2,name:'Task'}]}});
  if(url.pathname === '/projects.json') return json({projects:[{id:1,name:'Benchmark'}],total_count:1});
  if(url.pathname === '/trackers.json') return json({trackers:[{id:2,name:'Task'}]});
  return json({errors:['Unsupported local fixture endpoint']},404);
};
const server = http.createServer(handleRequest);
server.listen(8080, '0.0.0.0');
if (existsSync('/bench/.state/tls/cert.pem')) {
  https.createServer({key:readFileSync('/bench/.state/tls/key.pem'),cert:readFileSync('/bench/.state/tls/cert.pem'),minVersion:'TLSv1.2'},handleRequest).listen(8443,'0.0.0.0');
}
