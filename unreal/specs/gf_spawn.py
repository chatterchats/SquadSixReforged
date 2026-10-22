"""Mission-start off-navmesh rescue, ported from v1's spawn watch.

The main game state owns the brain; a separate current-world tactical state
supplies its player squad and is cached after a single actor-class lookup. Stops
permanently at the first preparation area (including activated areas on reload).
All counters and scratch arrays belong to this world-owned brain component.
"""
import math
from gf_graph import Graph, GS, KAL, KML, KSL
from gf_unstack import ACTOR, TACTICAL_STATE, SQUAD, NAV

AREA = '/Script/BitReactorGame.CombatPreparationArea'
PASSES = 150
SETTLE = 3


class G(Graph):
    def get(self, name, var):
        self.node(name, 'get', var=var)
        return f'{name}.{var}'

    def set(self, name, var, value=None):
        self.node(name, 'set', var=var, defaults={var: value} if value is not None else None)
        return f'{name}.{var}'

    def arr(self, name, operation, array, **pins):
        self.node(name, 'array_call', function=f'{KAL}:Array_{operation}')
        self.wire((array, f'{name}.TargetArray'), *((v, f'{name}.{k}') for k,v in pins.items()))

    def fn(self, name, inputs=(), outputs=()):
        return dict(name=name, inputs=[dict(name=n,type=t) for n,t in inputs],
                    outputs=[dict(name=n,type=t) for n,t in outputs], **self.spec())


def variables():
    fields = {'RescueState':f'object:{TACTICAL_STATE}', 'RescueStopped':'bool', 'RescuePasses':'int', 'SpawnRescued':'int', 'SpawnAttempts':'int',
              'RescueUnits':f'object:{ACTOR}[]', 'RescuePreviousUnits':f'object:{ACTOR}[]',
              'RescuePositions':'vector[]', 'RescueStill':'int[]', 'RescueNewPositions':'vector[]',
              'RescueNewStill':'int[]', 'RescueFloors':'vector[]', 'RescueWalkable':'bool[]',
              'RescueTried':f'object:{ACTOR}[]', 'RescueOnFloor':'int', 'RescueSettled':'int',
              'RescuePeer':f'object:{ACTOR}', 'RescuePeerFloor':'vector', 'RescueNearest':'float',
              'RescueMoved':'bool', 'RescueClear':'bool', 'RescueOffsets':'vector[]'}
    return [dict(name=n,type=t) for n,t in fields.items()]


def defaults():
    return {'RescueOffsets':'('+','.join(f'(X={r*math.cos(i*math.pi/4)},Y={r*math.sin(i*math.pi/4)},Z=0)'
                                       for r in (150,250) for i in range(8))+')'}


def event(g):
    g.node('spawnrescue', 'custom_event', name='SpawnRescue')
    g.call('spawnpass', 'self:SpawnRescuePass')
    g.chain('spawnrescue', 'spawnpass')


def floor():
    g=G()
    g.call('project',f'{NAV}:K2_ProjectPointToNavigation',{'QueryExtent':'50,50,250'})
    g.call('slide',f'{KML}:Vector_Distance2D')
    g.call('near',f'{KML}:LessEqual_DoubleDouble',{'B':50})
    g.call('origin',f'{KML}:VSize')
    g.call('placed',f'{KML}:Greater_DoubleDouble',{'B':1})
    g.call('ok1',f'{KML}:BooleanAND'); g.call('ok2',f'{KML}:BooleanAND')
    g.chain('entry','result')
    g.wire(('entry.Point','project.Point'),('entry.Point','slide.V1'),('project.ProjectedLocation','slide.V2'),
           ('slide.ReturnValue','near.A'),('entry.Point','origin.A'),('origin.ReturnValue','placed.A'),
           ('project.ReturnValue','ok1.A'),('near.ReturnValue','ok1.B'),('ok1.ReturnValue','ok2.A'),
           ('placed.ReturnValue','ok2.B'),('ok2.ReturnValue','result.Ok'),('project.ProjectedLocation','result.Floor'))
    return g.fn('RescueFloor',[('Point','vector')],[('Ok','bool'),('Floor','vector')])


def watch():
    g=G()
    g.get('stop','RescueStopped'); g.node('stopped','branch')
    g.get('passes','RescuePasses'); g.call('expired',f'{KML}:GreaterEqual_IntInt',{'B':PASSES})
    g.node('timeout','branch'); g.call('finish','self:RescueFinish')
    g.call('resolve','self:RescueResolveState')
    g.get('state','RescueState'); g.call('validstate',f'{KSL}:IsValid'); g.node('statevalid','branch')
    g.node('prep','get',var=f'{TACTICAL_STATE}:CombatPreparationArea')
    g.call('validprep',f'{KSL}:IsValid'); g.node('deployed','branch')
    g.call('areas',f'{GS}:GetAllActorsOfClass',{'ActorClass':AREA})
    g.node('arealoop','macro',macro='ForEachLoop'); g.node('area','cast',**{'class':AREA})
    g.call('activated',f'{AREA}:HasActivated'); g.call('triggered',f'{AREA}:HasTriggered')
    g.call('started',f'{KML}:BooleanOR'); g.node('startedbranch','branch')
    g.call('finisharea','self:RescueFinish'); g.get('stop2','RescueStopped'); g.node('gate','branch')
    g.call('inc',f'{KML}:Add_IntInt',{'B':1}); g.set('count','RescuePasses')
    g.node('squad','get',var=f'{TACTICAL_STATE}:PlayerSquad')
    g.call('validsquad',f'{KSL}:IsValid'); g.node('squadgate','branch')
    g.call('members',f'{SQUAD}:GetSquadMembers'); g.set('units','RescueUnits')
    g.get('getunits','RescueUnits'); g.arr('len','Length','getunits.RescueUnits')
    g.call('expanded',f'{KML}:Greater_IntInt',{'B':4}); g.node('expandedgate','branch')
    g.call('snapshot','self:RescueSnapshot'); g.get('floorcount','RescueOnFloor')
    g.call('twice',f'{KML}:Multiply_IntInt',{'B':2}); g.call('half',f'{KML}:GreaterEqual_IntInt')
    g.node('enough','branch'); g.node('loop','macro',macro='ForEachLoop')
    g.call('check','self:RescueCheck')
    g.chain('entry','stopped'); g.chain('stopped.else','timeout')
    g.chain('timeout','finish'); g.chain('timeout.else','resolve','statevalid'); g.chain('statevalid','deployed')
    g.chain('deployed','finish'); g.chain('deployed.else','areas','arealoop.Exec')
    g.chain('arealoop.LoopBody','area'); g.chain('area','startedbranch'); g.chain('startedbranch','finisharea')
    g.chain('arealoop.Completed','gate'); g.chain('gate.else','count','squadgate')
    g.chain('squadgate','units','expandedgate'); g.chain('expandedgate','snapshot','enough')
    g.chain('enough','loop.Exec'); g.chain('loop.LoopBody','check')
    g.wire(('stop.RescueStopped','stopped.Condition'),('passes.RescuePasses','expired.A'),('expired.ReturnValue','timeout.Condition'),
           ('state.RescueState','validstate.Object'),('validstate.ReturnValue','statevalid.Condition'),('state.RescueState','prep.self'),('prep.CombatPreparationArea','validprep.Object'),
           ('validprep.ReturnValue','deployed.Condition'),('areas.OutActors','arealoop.Array'),('arealoop.Array Element','area.Object'),
           ('area.AsCombat Preparation Area','activated.self'),('area.AsCombat Preparation Area','triggered.self'),
           ('activated.ReturnValue','started.A'),('triggered.ReturnValue','started.B'),('started.ReturnValue','startedbranch.Condition'),
           ('stop2.RescueStopped','gate.Condition'),('passes.RescuePasses','inc.A'),('inc.ReturnValue','count.RescuePasses'),
           ('state.RescueState','squad.self'),('squad.PlayerSquad','validsquad.Object'),('validsquad.ReturnValue','squadgate.Condition'),
           ('squad.PlayerSquad','members.self'),('members.ReturnValue','units.RescueUnits'),('len.ReturnValue','expanded.A'),
           ('expanded.ReturnValue','expandedgate.Condition'),('floorcount.RescueOnFloor','twice.A'),('twice.ReturnValue','half.A'),
           ('len.ReturnValue','half.B'),('half.ReturnValue','enough.Condition'),('getunits.RescueUnits','loop.Array'),
           ('loop.Array Element','check.Unit'),('loop.Array Index','check.Index'))
    return g.fn('SpawnRescuePass')


def snapshot():
    g=G(); chain=['entry']
    for i,var in enumerate(('RescueNewPositions','RescueNewStill','RescueFloors','RescueWalkable')):
        g.get(f'a{i}',var); g.arr(f'clear{i}','Clear',f'a{i}.{var}'); chain.append(f'clear{i}')
    g.set('zero','RescueOnFloor',0); chain+=['zero','loop.Exec']
    g.get('units','RescueUnits'); g.node('loop','macro',macro='ForEachLoop')
    g.call('one','self:RescueObserve'); g.wire(('units.RescueUnits','loop.Array'),('loop.Array Element','one.Unit'))
    g.chain(*chain); g.chain('loop.LoopBody','one')
    chain=['loop.Completed']
    for i,(src,dst) in enumerate((('RescueNewPositions','RescuePositions'),('RescueNewStill','RescueStill'),('RescueUnits','RescuePreviousUnits'))):
        g.get(f'src{i}',src); g.set(f'dst{i}',dst); g.wire((f'src{i}.{src}',f'dst{i}.{dst}')); chain.append(f'dst{i}')
    g.chain(*chain)
    return g.fn('RescueSnapshot')


def observe():
    g=G(); g.set('zero','RescueSettled',0)
    g.get('previous','RescuePreviousUnits'); g.arr('find','Find','previous.RescuePreviousUnits',ItemToFind='entry.Unit')
    g.call('known',f'{KML}:GreaterEqual_IntInt',{'B':0}); g.node('knownbranch','branch')
    g.get('pos','RescuePositions'); g.arr('old','Get','pos.RescuePositions',Index='find.ReturnValue')
    g.call('loc',f'{ACTOR}:K2_GetActorLocation'); g.call('distance',f'{KML}:Vector_Distance')
    g.call('still',f'{KML}:Less_DoubleDouble',{'B':10}); g.node('stillbranch','branch')
    g.get('counts','RescueStill'); g.arr('oldcount','Get','counts.RescueStill',Index='find.ReturnValue')
    g.call('inc',f'{KML}:Add_IntInt',{'B':1}); g.set('settled','RescueSettled')
    g.call('record','self:RescueRecord')
    g.chain('entry','zero','knownbranch'); g.chain('knownbranch','stillbranch'); g.chain('stillbranch','settled','record')
    g.chain('knownbranch.else','record'); g.chain('stillbranch.else','record')
    g.wire(('find.ReturnValue','known.A'),('known.ReturnValue','knownbranch.Condition'),('entry.Unit','loc.self'),
           ('loc.ReturnValue','distance.V1'),('old.Item','distance.V2'),('distance.ReturnValue','still.A'),
           ('still.ReturnValue','stillbranch.Condition'),('oldcount.Item','inc.A'),('inc.ReturnValue','settled.RescueSettled'),
           ('entry.Unit','record.Unit'))
    return g.fn('RescueObserve',[('Unit',f'object:{ACTOR}')])


def record():
    g=G(); g.call('loc',f'{ACTOR}:K2_GetActorLocation'); g.call('floor','self:RescueFloor')
    g.get('still','RescueSettled')
    chain=['entry','floor']
    for i,(var,pin) in enumerate((('RescueNewPositions','loc.ReturnValue'),('RescueNewStill','still.RescueSettled'),
                                ('RescueFloors','floor.Floor'),('RescueWalkable','floor.Ok'))):
        g.get(f'a{i}',var); g.arr(f'add{i}','Add',f'a{i}.{var}',NewItem=pin); chain.append(f'add{i}')
    g.node('ok','branch'); g.get('count','RescueOnFloor'); g.call('inc',f'{KML}:Add_IntInt',{'B':1}); g.set('setcount','RescueOnFloor')
    g.chain(*chain,'ok'); g.chain('ok','setcount')
    g.wire(('entry.Unit','loc.self'),('loc.ReturnValue','floor.Point'),('floor.Ok','ok.Condition'),
           ('count.RescueOnFloor','inc.A'),('inc.ReturnValue','setcount.RescueOnFloor'))
    return g.fn('RescueRecord',[('Unit',f'object:{ACTOR}')])


def check():
    g=G(); g.get('ok','RescueWalkable'); g.arr('walkable','Get','ok.RescueWalkable',Index='entry.Index')
    g.node('onground','branch'); g.get('still','RescueStill'); g.arr('count','Get','still.RescueStill',Index='entry.Index')
    g.call('settled',f'{KML}:GreaterEqual_IntInt',{'B':SETTLE}); g.node('settledgate','branch')
    g.get('tried','RescueTried'); g.arr('contains','Contains','tried.RescueTried',ItemToFind='entry.Unit'); g.node('triedgate','branch')
    g.call('loc',f'{ACTOR}:K2_GetActorLocation'); g.call('size',f'{KML}:VSizeXY'); g.call('placed',f'{KML}:Greater_DoubleDouble',{'B':100})
    g.node('placedgate','branch'); g.call('peer','self:RescueFindPeer'); g.get('getpeer','RescuePeer')
    g.call('validpeer',f'{KSL}:IsValid'); g.node('peergate','branch')
    g.arr('remember','Add','tried.RescueTried',NewItem='entry.Unit')
    g.get('attempts','SpawnAttempts'); g.call('inc',f'{KML}:Add_IntInt',{'B':1}); g.set('attempt','SpawnAttempts')
    g.call('move','self:RescueMove')
    g.chain('entry','onground'); g.chain('onground.else','settledgate'); g.chain('settledgate','triedgate')
    g.chain('triedgate.else','placedgate'); g.chain('placedgate','peer','peergate'); g.chain('peergate','remember','attempt','move')
    g.wire(('walkable.Item','onground.Condition'),('count.Item','settled.A'),('settled.ReturnValue','settledgate.Condition'),
           ('contains.ReturnValue','triedgate.Condition'),('entry.Unit','loc.self'),('loc.ReturnValue','size.A'),
           ('size.ReturnValue','placed.A'),('placed.ReturnValue','placedgate.Condition'),('entry.Unit','peer.Unit'),
           ('getpeer.RescuePeer','validpeer.Object'),('validpeer.ReturnValue','peergate.Condition'),
           ('attempts.SpawnAttempts','inc.A'),('inc.ReturnValue','attempt.SpawnAttempts'),('entry.Unit','move.Unit'))
    return g.fn('RescueCheck',[('Unit',f'object:{ACTOR}'),('Index','int')])


def peer():
    g=G(); g.set('clear','RescuePeer'); g.set('far','RescueNearest',2000)
    g.get('units','RescueUnits'); g.node('loop','macro',macro='ForEachLoop')
    g.get('floors','RescueWalkable'); g.arr('ok','Get','floors.RescueWalkable',Index='loop.Array Index'); g.node('walkable','branch')
    g.call('here',f'{ACTOR}:K2_GetActorLocation'); g.call('there',f'{ACTOR}:K2_GetActorLocation'); g.call('dist',f'{KML}:Vector_Distance')
    g.get('nearest','RescueNearest'); g.call('closer',f'{KML}:LessEqual_DoubleDouble'); g.node('close','branch')
    g.set('setpeer','RescuePeer'); g.set('setdistance','RescueNearest'); g.get('points','RescueFloors')
    g.arr('point','Get','points.RescueFloors',Index='loop.Array Index'); g.set('setfloor','RescuePeerFloor')
    g.chain('entry','clear','far','loop.Exec'); g.chain('loop.LoopBody','walkable'); g.chain('walkable','close')
    g.chain('close','setpeer','setdistance','setfloor')
    g.wire(('units.RescueUnits','loop.Array'),('ok.Item','walkable.Condition'),('entry.Unit','here.self'),
           ('loop.Array Element','there.self'),('here.ReturnValue','dist.V1'),('there.ReturnValue','dist.V2'),
           ('dist.ReturnValue','closer.A'),('nearest.RescueNearest','closer.B'),('closer.ReturnValue','close.Condition'),
           ('loop.Array Element','setpeer.RescuePeer'),('dist.ReturnValue','setdistance.RescueNearest'),('point.Item','setfloor.RescuePeerFloor'))
    return g.fn('RescueFindPeer',[('Unit',f'object:{ACTOR}')])


def clear_spot():
    g=G(); g.set('yes','RescueClear','true'); g.get('units','RescueUnits'); g.node('loop','macro',macro='ForEachLoop')
    g.call('loc',f'{ACTOR}:K2_GetActorLocation'); g.call('dist',f'{KML}:Vector_Distance2D')
    g.call('close',f'{KML}:Less_DoubleDouble',{'B':100}); g.node('blocked','branch'); g.set('no','RescueClear','false')
    g.chain('entry','yes','loop.Exec'); g.chain('loop.LoopBody','blocked'); g.chain('blocked','no')
    g.wire(('units.RescueUnits','loop.Array'),('loop.Array Element','loc.self'),('entry.Point','dist.V1'),
           ('loc.ReturnValue','dist.V2'),('dist.ReturnValue','close.A'),('close.ReturnValue','blocked.Condition'))
    return g.fn('RescueClearSpot',[('Point','vector')])


def move():
    g=G(); g.set('reset','RescueMoved','false'); g.get('offsets','RescueOffsets'); g.node('loop','macro',macro='ForEachLoop')
    g.get('moved','RescueMoved'); g.node('done','branch'); g.get('base','RescuePeerFloor'); g.call('candidate',f'{KML}:Add_VectorVector')
    g.call('floor','self:RescueFloor'); g.node('valid','branch'); g.call('a',f'{KML}:BreakVector'); g.call('b',f'{KML}:BreakVector')
    g.call('rise',f'{KML}:Subtract_DoubleDouble'); g.call('abs',f'{KML}:Abs'); g.call('level',f'{KML}:LessEqual_DoubleDouble',{'B':100})
    g.node('levelgate','branch'); g.call('free','self:RescueClearSpot'); g.get('clear','RescueClear'); g.node('freegate','branch')
    g.get('peer','RescuePeer'); g.call('loc',f'{ACTOR}:K2_GetActorLocation'); g.call('peerxyz',f'{KML}:BreakVector')
    g.call('lift',f'{KML}:Subtract_DoubleDouble'); g.call('z',f'{KML}:Add_DoubleDouble'); g.call('target',f'{KML}:MakeVector')
    g.call('teleport',f'{ACTOR}:K2_SetActorLocation',{'bTeleport':'true','bSweep':'false'}); g.node('accepted','branch')
    g.set('success','RescueMoved','true'); g.get('count','SpawnRescued'); g.call('inc',f'{KML}:Add_IntInt',{'B':1}); g.set('setcount','SpawnRescued')
    g.node('pawn','cast',**{'class':'/Script/Engine.Pawn'}); g.call('controller','/Script/Engine.Pawn:GetController')
    g.call('hascontroller',f'{KSL}:IsValid'); g.node('controllergate','branch'); g.call('halt','/Script/Engine.Controller:StopMovement')
    g.chain('entry','reset','loop.Exec'); g.chain('loop.LoopBody','done'); g.chain('done.else','floor','valid')
    g.chain('valid','levelgate'); g.chain('levelgate','free','freegate'); g.chain('freegate','teleport','accepted')
    g.chain('accepted','success','setcount','pawn'); g.chain('pawn','controllergate'); g.chain('controllergate','halt')
    g.wire(('offsets.RescueOffsets','loop.Array'),('moved.RescueMoved','done.Condition'),('base.RescuePeerFloor','candidate.A'),
           ('loop.Array Element','candidate.B'),('candidate.ReturnValue','floor.Point'),('floor.Ok','valid.Condition'),
           ('floor.Floor','a.InVec'),('base.RescuePeerFloor','b.InVec'),('a.Z','rise.A'),('b.Z','rise.B'),('rise.ReturnValue','abs.A'),
           ('abs.ReturnValue','level.A'),('level.ReturnValue','levelgate.Condition'),('floor.Floor','free.Point'),('clear.RescueClear','freegate.Condition'),
           ('peer.RescuePeer','loc.self'),('loc.ReturnValue','peerxyz.InVec'),('peerxyz.Z','lift.A'),('b.Z','lift.B'),
           ('a.Z','z.A'),('lift.ReturnValue','z.B'),('a.X','target.X'),('a.Y','target.Y'),('z.ReturnValue','target.Z'),
           ('entry.Unit','teleport.self'),('target.ReturnValue','teleport.NewLocation'),('teleport.ReturnValue','accepted.Condition'),
           ('count.SpawnRescued','inc.A'),('inc.ReturnValue','setcount.SpawnRescued'),('entry.Unit','pawn.Object'),
           ('pawn.AsPawn','controller.self'),('controller.ReturnValue','hascontroller.Object'),('hascontroller.ReturnValue','controllergate.Condition'),
           ('controller.ReturnValue','halt.self'))
    return g.fn('RescueMove',[('Unit',f'object:{ACTOR}')])


def resolve_state():
    g=G(); g.get('cached','RescueState'); g.call('valid',f'{KSL}:IsValid'); g.node('known','branch')
    g.call('states',f'{GS}:GetAllActorsOfClass',{'ActorClass':TACTICAL_STATE})
    g.arr('length','Length','states.OutActors'); g.call('any',f'{KML}:Greater_IntInt',{'B':0});g.node('found','branch')
    g.arr('first','Get','states.OutActors'); g.node('cast','cast',**{'class':TACTICAL_STATE}); g.set('keep','RescueState')
    g.chain('entry','known');g.chain('known.else','states','found');g.chain('found','cast');g.chain('cast','keep')
    g.wire(('cached.RescueState','valid.Object'),('valid.ReturnValue','known.Condition'),
           ('length.ReturnValue','any.A'),('any.ReturnValue','found.Condition'),('first.Item','cast.Object'),
           ('cast.AsTactical Game State','keep.RescueState'))
    return g.fn('RescueResolveState')


def finish():
    g=G(); g.set('stop','RescueStopped','true'); g.node('me','self')
    g.call('clear',f'{KSL}:K2_ClearTimer',{'FunctionName':'SpawnRescue'})
    g.chain('entry','stop','clear'); g.wire(('me.self','clear.Object'))
    return g.fn('RescueFinish')


def functions():
    return [resolve_state(), finish(), floor(), clear_spot(), move(), peer(), check(), record(), observe(), snapshot(), watch()]
