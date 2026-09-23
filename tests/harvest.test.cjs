const test=require('node:test'),assert=require('node:assert/strict');
const {payload,session}=require('../harvest-core.js');
const values={plantingId:'planting',quantity:'12.5',dateTime:'2026-09-23T09:30',workerId:'worker',notes:' First pick ',inventoryId:'stock'};
test('Harvest requires positive finite kilograms and keeps local reporting date',()=>{
 for(const quantity of ['', ' ', 'abc',0,-1,Infinity,NaN])assert.throws(()=>payload({...values,quantity},'request'));
 const data=payload(values,'request');assert.equal(data.p_quantity,12.5);assert.equal(data.p_harvest_date,'2026-09-23');assert.equal(data.p_notes,'First pick');assert.equal(data.p_worker_id,'worker');
 assert.throws(()=>payload({...values,dateTime:'invalid'},'request'));
});
test('Double-click and resubmission after success send only one harvest',async()=>{
 let calls=0,resolve;const s=session(()=>{calls++;return new Promise(r=>resolve=r);},'one');
 const first=s.submit(values),second=s.submit(values);assert.equal(first,second);
 await Promise.resolve();resolve('harvest');await Promise.all([first,second]);assert.equal(await s.submit(values),'harvest');assert.equal(calls,1);assert.equal(s.pending,false);
});
test('Lost response retries identical payload and request ID even if inputs changed',async()=>{
 const calls=[];const s=session(async data=>{calls.push(data);if(calls.length===1)throw Error('Network disconnected');return 'saved';},'stable');
 await assert.rejects(s.submit(values));assert.equal(s.pending,true);
 await s.submit({...values,quantity:99});assert.deepEqual(calls[0],calls[1]);assert.equal(calls[1].p_quantity,12.5);
});
test('Database rejection permits correcting a form without losing idempotency key',async()=>{
 const calls=[];const s=session(async data=>{calls.push(data);if(calls.length===1)throw Object.assign(Error('Record inventory count first'),{status:400});return 'saved';},'stable');
 await assert.rejects(s.submit(values));assert.equal(s.pending,false);
 await s.submit({...values,quantity:2.5});assert.equal(calls[1].p_quantity,2.5);assert.equal(calls[1].p_request_id,calls[0].p_request_id);
});
