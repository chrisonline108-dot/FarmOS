(function(root){
 'use strict';
 function payload(values,requestId){
  const quantity=Number(values.quantity),date=new Date(values.dateTime);
  if(String(values.quantity).trim()===''||!Number.isFinite(quantity)||quantity<=0)throw Error('Enter a harvest amount greater than 0 kg.');
  if(!values.dateTime||!Number.isFinite(date.getTime()))throw Error('Choose a valid harvest date and time.');
  return {p_planting_id:values.plantingId,p_quantity:quantity,p_harvested_at:date.toISOString(),p_harvest_date:values.dateTime.slice(0,10),p_worker_id:values.workerId||null,p_notes:values.notes?.trim()||null,p_request_id:requestId,p_inventory_id:values.inventoryId||null};
 }
 // Preserve an uncertain request verbatim on retry. A successful session cannot submit twice.
 function session(send,requestId){
  let pending=null,inflight=null,result,done=false;
  return {
   get pending(){return pending!==null&&!done;},
   submit(values){
    if(done)return Promise.resolve(result);
    if(inflight)return inflight;
    try{pending??=payload(values,requestId);}catch(e){return Promise.reject(e);}
    inflight=Promise.resolve().then(()=>send(pending)).then(value=>{done=true;result=value;return value;}).catch(e=>{
     // A structured HTTP rejection confirms that PostgreSQL rolled the request back.
     if(e.status>=400&&e.status<500)pending=null;
     throw e;
    }).finally(()=>{inflight=null;});
    return inflight;
   }
  };
 }
 const api={payload,session};if(typeof module==='object'&&module.exports)module.exports=api;else root.FarmHarvest=api;
})(typeof window==='object'?window:globalThis);
