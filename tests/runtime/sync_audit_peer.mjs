// Controlled peer for new sync-only audit scenarios; no real Redmine access.
import http from 'node:http';
let config={};let counts={};let connections=new Set();let bytes=0;
const handle=async(req,res)=>{
  const url=new URL(req.url,'http://redmine:8080');
  const json=(data,code=200)=>{const body=JSON.stringify(data);bytes+=Buffer.byteLength(body);res.writeHead(code,{'Content-Type':'application/json; charset=utf-8'});res.end(body);};
  if(url.pathname==='/__control'){
    let body='';for await(const part of req)body+=part;
    config=JSON.parse(body);counts={};connections=new Set();bytes=0;
    return json({ok:true});
  }
  if(url.pathname==='/__stats')return json({counts,connections:connections.size,open_connections:[...connections].filter(s=>!s.destroyed).length,response_bytes:bytes});
  const key=`${req.method} ${url.pathname}${url.search}`;counts[key]=(counts[key]||0)+1;connections.add(req.socket);
  if(url.pathname.startsWith('/attachments/download/')){
    if(config.fileError)return json({errors:['Controlled missing file']},404);
    const body=Buffer.alloc(config.fileBytes||1048576,82);bytes+=body.length;
    res.writeHead(200,{'Content-Type':'application/octet-stream','Content-Length':body.length});return res.end(body);
  }
  const issue=url.pathname.match(/^\/issues\/(\d+)\.json$/);
  if(issue){
    const include=url.searchParams.get('include')||'';
    const changed=Boolean(config.changed);
    const data={id:Number(issue[1]),status:{name:config.status||'New'},updated_on:changed?'2026-01-02T00:00:00Z':'2026-01-01T00:00:00Z',tracker:{id:2},project:{id:1}};
    if(include.includes('journals'))data.journals=Array.from({length:config.journals||0},(_,i)=>({id:11+i,user:{id:2,name:'Audit engineer'},notes:'<p>'+('ordinary '.repeat(config.noteWords||1))+'</p>',details:config.statusDetail?[{property:'attr',name:'status_id',old_value:'1',new_value:'2'}]:[]}));
    if(include.includes('attachments'))data.attachments=config.fileError||config.fileBytes?[{id:1,filename:'audit.bin',filesize:config.metadataBytes??config.fileBytes??1048576,content_type:'application/octet-stream'}]:[];
    return json({issue:data});
  }
  if(url.pathname==='/enumerations/issue_priorities.json')return json({issue_priorities:[{id:2,name:'Normal',is_default:true}]});
  if(url.pathname==='/projects/1.json')return json({project:{id:1,name:'Local audit',trackers:[{id:2,name:'Task'}]}});
  if(url.pathname==='/projects/1/memberships.json')return json({memberships:[{user:{id:2,name:'Local audit'}}],total_count:1});
  if(url.pathname==='/projects.json')return json({projects:[{id:1,name:'Local audit'}],total_count:1});
  return json({errors:['Unsupported audit endpoint']},404);
};
http.createServer(handle).listen(8080,'0.0.0.0');
