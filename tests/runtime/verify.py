"""Real OTRS behavior checks using the initialized, isolated runtime stack."""
import argparse
import hashlib
import json
import run as runtime

def main():
    m=runtime
    parser=argparse.ArgumentParser()
    parser.add_argument('--installed',action='store_true')
    args=parser.parse_args()
    variants=['installed'] if args.installed else ['before','after']
    current='installed' if args.installed else 'after'
    results={}
    for variant in variants:
        m.restore();m.perl(variant,'prepare','unchanged');m.peer_control('unchanged')
        batches=[m.perl(variant,'run','unchanged')['checks']['processed_tickets'] for _ in range(3)]
        visited=m.perl(variant,'verify-pages')['visited_tickets']
        results['pages_'+variant]={'batches':batches,'visited':visited}
        if variant!='before':
            assert visited==125
    for variant in variants:
        m.restore();m.perl(variant,'prepare','inbound');m.perl(variant,'close-incoming');m.peer_control('inbound')
        note=m.perl(variant,'run','inbound')
        replay=m.perl(variant,'verify-replay')
        results['state_and_notes_'+variant]={'checks':note['checks'],'replay':replay}
    m.restore();m.perl(current,'prepare','binary');m.perl(current,'close-incoming');m.peer_control('binary')
    results['binary_'+current]=m.perl(current,'run','binary')['checks']
    for scenario in ['outbound','extra']:
        m.restore();m.perl(current,'prepare',scenario)
        if scenario=='extra':
            m.perl(current,'extra-setup')
        script='fetch("http://localhost:8080/__control",{method:"POST",body:JSON.stringify({scenario:process.argv[1],verifyUploads:true})}).then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
        m.command(['docker','exec',m.PEER,'node','-e',script,scenario])
        result=m.perl(current,'run',scenario);peer=m.peer_stats()
        count=16 if scenario=='outbound' else 1
        size=1024*1024 if scenario=='outbound' else 512*1024
        payload=b'A'*size if scenario=='outbound' else b'E'*size
        assert peer['uploaded_hashes']==[hashlib.sha256(payload).hexdigest()]*count
        assert [f['token'] for f in peer['attached']]==['bench-'+str(i) for i in range(1,count+1)]
        results['upload_'+scenario]={'checks':result['checks'],'files':count,'bytes_each':size,'hashes_verified':True,'tokens_attached':True}
    destination=m.RESULTS/'final-review'/'functional-installed.json' if args.installed else m.RESULTS/'functional.json'
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(results,ensure_ascii=False,indent=2))

if __name__=='__main__':
    main()
