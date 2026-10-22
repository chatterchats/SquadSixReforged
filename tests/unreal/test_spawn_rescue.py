"""Execute the rescue graphs with a deterministic navigation fixture.

Navigation and the reconstructed kit's stub squad-members getter are replaced: this exercises real compiled Blueprint control flow,
actor movement and counters without relying on game maps or generated nav data.
It does not establish navigation/intro behavior in the shipping game.
"""
import json
import os
import sys
import traceback
from pathlib import Path
import unreal
import zcom_authoring

repo=Path(os.environ['SQUADSIX_REPO'])
sys.path.insert(0,str(repo/'unreal/specs'))
import gf_spawn as spawn
from gf_graph import KML

checks=0
actors=[]
api=unreal.get_editor_subsystem(unreal.EditorActorSubsystem)

def check(ok,label):
    global checks
    checks+=1
    unreal.log(f'SPAWN_TEST {"ok" if ok else "FAIL"}: {label}')
    assert ok,label


def actor(x,y=1000,z=100):
    a=api.spawn_actor_from_class(unreal.StaticMeshActor,unreal.Vector(x,y,z),unreal.Rotator(),transient=True)
    actors.append(a)
    return a


def get(b,n):return b.get_editor_property(n)
def put(b,n,v):b.call_method('TestSet'+n,(v,))
def call(b,n,*args):return b.call_method(n,args)

try:
    # Deterministic walkable region: x < 1500, flat floor at Z=0.
    g=spawn.G(); g.get('ready','FixtureNavReady'); g.call('xyz',f'{KML}:BreakVector')
    g.call('inside',f'{KML}:Less_DoubleDouble',{'B':1500});g.call('ok',f'{KML}:BooleanAND')
    g.call('floor',f'{KML}:MakeVector',{'Z':0});g.chain('entry','result')
    g.wire(('entry.Point','xyz.InVec'),('xyz.X','inside.A'),('ready.FixtureNavReady','ok.A'),
           ('inside.ReturnValue','ok.B'),('ok.ReturnValue','result.Ok'),('xyz.X','floor.X'),('xyz.Y','floor.Y'),('floor.ReturnValue','result.Floor'))
    fixture=g.fn('RescueFloor',[('Point','vector')],[('Ok','bool'),('Floor','vector')])
    path='/Game/SquadSixTests/BP_SpawnRescueFixture'
    spec=dict(kind='blueprint',path=path,parent='/Script/Engine.ActorComponent',
              variables=spawn.variables()+[dict(name='FixtureNavReady',type='bool',default='true'),dict(name='FixtureUnits',type='object:/Script/Engine.Actor[]')],
              functions=[fixture if f['name']=='RescueFloor' else f for f in spawn.functions()],defaults=spawn.defaults())
    watch=next(f for f in spec['functions'] if f['name']=='SpawnRescuePass')
    members=next(n for n in watch['nodes'] if n['id']=='members')
    members.clear();members.update(id='members',kind='get',var='FixtureUnits')
    watch['links']=[[a.replace('members.ReturnValue','members.FixtureUnits'),b] for a,b in watch['links'] if b!='members.self']
    for var in spec['variables']:

        setter=spawn.G();setter.set('set',var['name']);setter.chain('entry','set')
        setter.wire(('entry.Value','set.'+var['name']))
        spec['functions'].append(setter.fn('TestSet'+var['name'],[('Value',var['type'])]))
    dest=repo/'dist/gf-tests';dest.mkdir(parents=True,exist_ok=True)
    source=dest/'spawn-fixture.json';source.write_text(json.dumps(spec))
    assert zcom_authoring.build([source])
    cls=unreal.EditorAssetLibrary.load_blueprint_class(path)
    def brain():return unreal.new_object(cls,outer=actor(10000,10000))
    def squad(b,coords=(1000,800,600,400,2000,2200)):
        units=[actor(x) for x in coords];put(b,'RescueUnits',units);return units
    def snapshot(b,n=1):
        for _ in range(n):call(b,'RescueSnapshot')

    b=brain();units=squad(b);snapshot(b,3)
    call(b,'RescueCheck',units[4],4)
    check(get(b,'SpawnAttempts')==0,'three observations alone are not three stationary intervals')
    snapshot(b);check(get(b,'RescueOnFloor')==4,'snapshot counts walkable squadmates')
    before=units[4].get_actor_location();call(b,'RescueCheck',units[4],4)
    after=units[4].get_actor_location()
    check(get(b,'SpawnRescued')==1 and after.x<1500 and abs(after.z-100)<.01,'off-navmesh operator rescued beside a peer with capsule lift preserved')
    check(all((after-u.get_actor_location()).length()>=99.9 for i,u in enumerate(units) if i!=4),'destination clears occupied positions')
    units[4].set_actor_location(before,False,False);snapshot(b,4);call(b,'RescueCheck',units[4],4)
    check(get(b,'SpawnAttempts')==1,'script returning an operator does not cause repeated rescue')

    b=brain();units=squad(b);snapshot(b,4)
    units[4].set_actor_location(unreal.Vector(2010,1000,100),False,False);snapshot(b);call(b,'RescueCheck',units[4],4)
    check(get(b,'SpawnAttempts')==0,'moving operator resets settling and is not rescued')
    call(b,'RescueCheck',units[0],0)
    check(get(b,'SpawnAttempts')==0,'stationary walkable operator is untouched')
    put(b,'FixtureNavReady',False);snapshot(b,4);call(b,'RescueCheck',units[4],4)
    check(get(b,'SpawnAttempts')==0,'no navigation means no valid rescue peer')

    b=brain();units=squad(b,(1000,800,600,400,5000,5200));snapshot(b,4);call(b,'RescueCheck',units[4],4)
    check(get(b,'SpawnAttempts')==0,'peer farther than 2000 units is refused')
    b=brain();units=squad(b,(1000,800,600,400,0,2200));units[4].set_actor_location(unreal.Vector(0,0,100),False,False)
    snapshot(b,4);call(b,'RescueCheck',units[4],4)
    check(get(b,'SpawnAttempts')==0,'unplaced world-origin operator is ignored')
    b=brain();put(b,'RescueStopped',True);call(b,'SpawnRescuePass')
    check(get(b,'RescuePasses')==0,'permanent stop gate prevents further work')
    b=brain();put(b,'RescuePasses',spawn.PASSES);call(b,'SpawnRescuePass')
    check(get(b,'RescueStopped'),'five-minute timeout permanently stops watch')

    # Reordered members keep settlement by actor identity, not array index.
    b=brain();units=squad(b);snapshot(b,4);put(b,'RescueUnits',list(reversed(units)));snapshot(b)
    check(list(get(b,'RescueStill'))==[4]*6,'squad reordering preserves identity-based history')
    newcomer=actor(2100);put(b,'RescueUnits',[newcomer]+units);snapshot(b)
    check(get(b,'RescueStill')[0]==0,'new joiner starts with no stationary history')
    # The kit's native GetSquadMembers is reconstructed; only that read is supplied
    # by the fixture. Owner, squad validation, gates and the remaining graphs execute.
    tactical_states=[]
    def tactical_brain():
        for old in tactical_states:
            api.destroy_actor(old);actors.remove(old)
        tactical_states.clear()
        state=api.spawn_actor_from_class(unreal.load_class(None,spawn.TACTICAL_STATE),unreal.Vector(),unreal.Rotator(),transient=True)
        actors.append(state);tactical_states.append(state)
        sq=api.spawn_actor_from_class(unreal.load_class(None,spawn.SQUAD),unreal.Vector(),unreal.Rotator(),transient=True)
        actors.append(sq);state.set_editor_property('PlayerSquad',sq)
        return unreal.new_object(cls,outer=actor(10000,10000)),state
    b,state=tactical_brain();units=squad(b,(1000,800,2000,2200));put(b,'FixtureUnits',units)
    for _ in range(5):call(b,'SpawnRescuePass')
    check(get(b,'RescueState')==state,'brain on a separate owner resolves the current-world tactical state')
    check(get(b,'SpawnAttempts')==0 and len(get(b,'RescuePositions'))==0,'stock four-person squad is not watched or rescued')
    b,state=tactical_brain();units=squad(b,(1000,800,2000,2200,2400,2600));put(b,'FixtureUnits',units)
    for _ in range(5):call(b,'SpawnRescuePass')
    check(get(b,'RescueOnFloor')==2 and get(b,'SpawnAttempts')==0,'fewer than half on navigation suppresses all rescues')
    b,state=tactical_brain();units=squad(b);put(b,'FixtureUnits',units)
    for _ in range(4):call(b,'SpawnRescuePass')
    check(get(b,'SpawnRescued')==2,'full watch rescues both stranded members after settling')
    prep_spec=dict(kind='blueprint',path='/Game/SquadSixTests/BP_TestPrep',parent=spawn.AREA)
    assert json.loads(unreal.ZComAuthoringLibrary.build_asset_from_json(json.dumps(prep_spec)))['ok']
    prep=api.spawn_actor_from_class(unreal.EditorAssetLibrary.load_blueprint_class(prep_spec['path']),unreal.Vector(),unreal.Rotator(),transient=True)
    actors.append(prep)
    b,state=tactical_brain();state.set_editor_property('CombatPreparationArea',prep);call(b,'SpawnRescuePass')
    check(get(b,'RescueStopped') and get(b,'RescuePasses')==0,'first combat preparation permanently stops rescue before inspecting squad')
    unreal.log(f'SPAWN_RESULT ok checks={checks}')
except Exception:
    unreal.log_error(traceback.format_exc());unreal.log_error('SPAWN_RESULT failed')
finally:
    for a in actors:api.destroy_actor(a)
    # Isolated test asset is outside /SquadSixGF and never included by its DLC cook.
