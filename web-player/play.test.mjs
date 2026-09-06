import assert from 'node:assert/strict'
import test from 'node:test'
import { challengeID, parsePlayMessage } from './play.mjs'

test('challenge links require one valid identifier and preserve UUID', () => {
 const id = '11111111-1111-4111-8111-111111111111'
 assert.equal(challengeID(`?challenge=${id}`),id)
 assert.equal(challengeID(''),undefined)
 for(const query of ['?challenge=bad',`?challenge=${id}&challenge=${id}`,'?challenge='])assert.throws(()=>challengeID(query))
})
test('result messages accept only integer scores and fixed event names', () => {
 assert.deepEqual(parsePlayMessage({type:'pulse:play-v1',name:'complete',score:42}),{name:'complete',score:42})
 for(const score of [true,-1,1.5,Infinity,NaN,1e9+1,'42',null])assert.equal(parsePlayMessage({type:'pulse:play-v1',name:'complete',score}),null)
 assert.equal(parsePlayMessage({type:'other',name:'interaction'}),null)
 assert.equal(parsePlayMessage({type:'pulse:play-v1',name:'navigate',url:'https://example.org'}),null)
 assert.deepEqual(parsePlayMessage({type:'pulse:play-v1',name:'interaction',secret:'not propagated'}),{name:'interaction'})
})
