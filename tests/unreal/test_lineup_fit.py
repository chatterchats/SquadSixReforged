"""Execute the squad screen's lineup fit (FitLineup, CaptureLayout, PlaceProxy, RestoreScales) on editor actors.

Only CountUsed and CountShown's widget count are replaced (the squad comes from FixtureUsed and the nameplates from
FixtureShown instead of the screen); the rest is the compiled graph the Brain ships. Proxies stand in for the game's: four
authored ones hanging in diorama "slots" 45 uu apart, attached snapped as the game attaches them, each slot with its own
scale; and two overflow ones the game never places or scales. Setting an authored proxy's scale stands in for the slot
snapping a newly attached character. It does not establish what the game's diorama does; that takes the shipping game
(docs/live-tests.md).
"""
import json
import os
import sys
import traceback
from pathlib import Path
import unreal
import zcom_authoring

repo = Path(os.environ['SQUADSIX_REPO'])
sys.path.insert(0, str(repo / 'unreal/specs'))
import gf_lineup as lineup
from gf_spawn import G
from gf_graph import KML

checks = 0
actors = []
api = unreal.get_editor_subsystem(unreal.EditorActorSubsystem)
BASES = (1.0, 1.1, 0.9, 1.2)  # the authored slots' scales
SLOT_STEP = 45.0
SNAP = unreal.AttachmentRule.SNAP_TO_TARGET


def check(ok, label):
    global checks
    checks += 1
    unreal.log(f'LINEUP_TEST {"ok" if ok else "FAIL"}: {label}')
    assert ok, label


def spawn(x, scale):
    a = api.spawn_actor_from_class(unreal.StaticMeshActor, unreal.Vector(x, 0, 100), unreal.Rotator(), transient=True)
    a.static_mesh_component.set_mobility(unreal.ComponentMobility.MOVABLE)
    a.set_actor_scale3d(unreal.Vector(scale, scale, scale))
    actors.append(a)
    return a


def scales(units):
    return [round(u.get_actor_scale3d().x, 4) for u in units]


def fitted(used, shown):
    return 3 / (shown - 1) if shown > lineup.AUTHORED else 1


def expect(units, used, bases, label, shown=None):
    shown = max(shown or used, used)
    fit = fitted(used, shown)
    want = [round(b * fit, 4) for b in bases[:min(used, lineup.AUTHORED)]]
    want += [round(bases[lineup.AUTHORED - 1] * fit, 4)] * (used - lineup.AUTHORED)
    got = scales(units)[:len(want)]
    check(all(abs(g - w) < 1e-3 for g, w in zip(got, want)), f'{label}: want {want}, got {got}')


def expect_row(units, used, shown, label):
    """Model i on a row of `shown`, centred on the authored row, ROW_STEP_RATIO of its step apart."""
    centre = SLOT_STEP * (lineup.AUTHORED - 1) / 2
    want = [round(centre + (i - (shown - 1) / 2) * lineup.ROW_STEP_RATIO * SLOT_STEP, 2) for i in range(used)]
    got = [round(u.get_actor_location().x, 2) for u in units[:used]]
    check(all(abs(g - w) < 0.05 for g, w in zip(got, want)), f'{label}: want x {want}, got {got}')


def expect_slots(units, used, label):
    """Each authored model back where its slot holds it: the slot's place, relative zero."""
    got = [round(u.get_actor_location().x, 2) for u in units[:used]]
    want = [i * SLOT_STEP for i in range(used)]
    check(all(abs(g - w) < 0.05 for g, w in zip(got, want)), f'{label}: want x {want}, got {got}')


try:
    count = G()
    count.get('want', 'FixtureUsed')
    count.set('set', 'Used')
    count.get('slots', 'FixtureFilled')
    count.set('setfilled', 'Filled')
    count.chain('entry', 'set', 'setfilled')
    count.wire(('want.FixtureUsed', 'set.Used'), ('slots.FixtureFilled', 'setfilled.Filled'))
    # CountShown without widgets: FixtureShown plates, never fewer than Used (as the shipped graph).
    shown = G()
    shown.get('plates', 'FixtureShown')
    shown.get('used', 'Used')
    shown.call('atleast', f'{KML}:Max')
    shown.set('set', 'Shown')
    shown.chain('entry', 'set')
    shown.wire(('plates.FixtureShown', 'atleast.A'), ('used.Used', 'atleast.B'), ('atleast.ReturnValue', 'set.Shown'))
    functions = [f for f in lineup.functions() if f['name'] in
                 ('CaptureLayout', 'PlaceProxy', 'RestoreScales', 'FitLineup')]
    # PickerOpen without the input subsystem: FixturePicker.
    picker = G()
    picker.get('open', 'FixturePicker')
    picker.chain('entry', 'result')
    picker.wire(('open.FixturePicker', 'result.Open'))
    functions += [count.fn('CountUsed'), shown.fn('CountShown'), picker.fn('PickerOpen', outputs=[('Open', 'bool')])]
    variables = lineup.variables() + [dict(name='FixtureUsed', type='int', default='0'),
                                      dict(name='FixtureFilled', type='bool[]'),
                                      dict(name='FixtureShown', type='int', default='0'),
                                      dict(name='FixturePicker', type='bool', default='false')]
    for var in ('Proxies', 'FixtureUsed', 'FixtureFilled', 'FixtureShown', 'FixturePicker'):
        setter = G()
        setter.set('set', var)
        setter.chain('entry', 'set')
        setter.wire(('entry.Value', f'set.{var}'))
        kind = next(v['type'] for v in variables if v['name'] == var)
        functions.append(setter.fn(f'TestSet{var}', [('Value', kind)]))
    path = '/Game/SquadSixTests/BP_LineupFitFixture'
    spec = dict(kind='blueprint', path=path, parent='/Script/Engine.ActorComponent',
                variables=variables, functions=functions)
    dest = repo / 'dist/gf-tests'
    dest.mkdir(parents=True, exist_ok=True)
    source = dest / 'lineup-fit-fixture.json'
    source.write_text(json.dumps(spec))
    assert zcom_authoring.build([source])
    cls = unreal.EditorAssetLibrary.load_blueprint_class(path)

    def brain():
        units = []
        for i, s in enumerate(BASES):
            slot = spawn(i * SLOT_STEP, s)
            unit = spawn(500, 1.0)
            unit.attach_to_actor(slot, 'None', SNAP, SNAP, SNAP, False)
            units.append(unit)
        units += [spawn(0, 1.0), spawn(0, 1.0)]
        b = unreal.new_object(cls, outer=spawn(10000, 1.0))
        b.call_method('TestSetProxies', (units,))
        return b, units

    def squad(b, used, plates=0, passes=3, holes=()):
        """The squad screen with slots up to `used` filled but `holes`, and `plates` nameplates up, for a few ticks."""
        b.call_method('TestSetFixtureUsed', (used,))
        b.call_method('TestSetFixtureFilled', ([i < used and i not in holes for i in range(6)],))
        b.call_method('TestSetFixtureShown', (plates,))
        for _ in range(passes):
            b.call_method('FitLineup', ())

    # The compounding shrink (player report on 2.0.3).
    b, units = brain()
    squad(b, 6)
    expect(units, 6, BASES, 'six: each model at its own scale times 3/5')
    expect_row(units, 6, 6, 'six: the row of six')
    squad(b, 5)
    expect(units, 5, BASES, 'five, no EMPTY plate: each model at its own scale times 3/4')
    squad(b, 6)
    expect(units, 6, BASES, 'adding a sixth back: the row returns to 3/5, not below it')
    for n in range(5):
        squad(b, 5, 6)
        squad(b, 6)
    expect(units, 6, BASES, 'five more remove/add swaps: no compounding')
    squad(b, 4)
    expect(units, 4, BASES, 'down to four: every model back at its own scale')
    expect_slots(units, 4, 'down to four: every model back in its slot')
    squad(b, 6)
    expect(units, 6, BASES, 'four to six: fitted from the restored scales')

    # The diorama slot snaps a newly attached character to its slot's scale: that is the new base.
    units[2].set_actor_scale3d(unreal.Vector(1.3, 1.3, 1.3))
    squad(b, 6)
    swapped = list(BASES)
    swapped[2] = 1.3
    expect(units, 6, swapped, 'a new character in slot three is fitted from its own scale')
    squad(b, 5, 6)
    squad(b, 6)
    expect(units, 6, swapped, 'and keeps it through a remove/add swap')

    # The EMPTY plate: below the maximum the game shows one more plate than the squad has.
    b, units = brain()
    squad(b, 6)
    squad(b, 5, 6)
    expect(units, 5, BASES, 'five and EMPTY: scaled as a row of six', shown=6)
    expect_row(units, 5, 6, 'five and EMPTY: each model over its own plate of six')
    squad(b, 4, 5)
    expect(units, 4, BASES, 'four and EMPTY: scaled as a row of five', shown=5)
    expect_row(units, 4, 5, 'four and EMPTY: each model over its own plate of five')
    squad(b, 3, 4)
    expect(units, 3, BASES, 'three and EMPTY: four plates, the game\'s own size', shown=4)
    expect_slots(units, 3, 'three and EMPTY: each model back in its slot under the authored plates')
    squad(b, 6)
    expect(units, 6, BASES, 'back to six from three')
    expect_row(units, 6, 6, 'back to six from three: the row of six')

    # Visibility: overflow models past the squad are hidden once it settles with the picker closed.
    def hidden(units):
        return [bool(u.get_editor_property('bHidden')) for u in units[lineup.AUTHORED:]]

    def picker(b, open_):
        b.call_method('TestSetFixturePicker', (open_,))

    def preview(units):
        units[5].set_actor_hidden_in_game(False)  # the game clones the hovered character in and shows it

    settle = lineup.SETTLE_PASSES + 2
    b, units = brain()
    squad(b, 6, passes=settle)
    check(hidden(units) == [False, False], f'six: both overflow models shown, got {hidden(units)}')
    squad(b, 5, 6, passes=1)
    check(hidden(units) == [False, False], f'five, just removed: not hidden before the squad settles, got {hidden(units)}')
    squad(b, 5, 6, passes=settle)
    check(hidden(units) == [False, True], f'five, settled: the removed sixth hidden, got {hidden(units)}')
    picker(b, True)
    preview(units)
    squad(b, 5, 6, passes=settle)
    check(hidden(units) == [False, False], f'picker open: the previewed sixth stays shown, got {hidden(units)}')
    picker(b, False)
    squad(b, 5, 6, passes=settle)
    check(hidden(units) == [False, True], f'picker cancelled: the preview is hidden again, got {hidden(units)}')
    picker(b, True)
    preview(units)
    squad(b, 5, 6, passes=2)
    picker(b, False)
    squad(b, 5, 6, passes=1)  # the picker closes a pass before the slot counts the pick
    squad(b, 6, passes=settle)
    check(hidden(units) == [False, False], f'picked: the sixth stays shown, got {hidden(units)}')
    squad(b, 4, 5, passes=settle)
    check(hidden(units) == [True, True], f'four, settled: both overflow models hidden, got {hidden(units)}')
    parked = [round(units[i].get_actor_location().length(), 2) for i in (4, 5)]
    check(parked == [0, 0], f'four, settled: both parked at the origin with their weapons, got {parked}')

    # The picker's preview slot (Used) is placed while the game shows it, and only then.
    picker(b, True)
    squad(b, 4, 6, passes=2)
    at = round(units[4].get_actor_location().length(), 2)
    check(at == 0, f'picker open, slot five not shown yet: left parked, got |loc| {at}')
    units[4].set_actor_hidden_in_game(False)  # the game previews the hovered character in slot five
    squad(b, 4, 6, passes=2)
    expect_row(units, 5, 6, 'picker open: the previewed fifth stands in the row of six')
    expect(units, 5, BASES, 'picker open: the previewed fifth at the row size', shown=6)
    picker(b, False)

    # Holes: a fifth removed with the sixth still in the squad (Used stays six).
    b, units = brain()
    squad(b, 6, passes=settle)
    squad(b, 6, passes=settle, holes=(4,))
    check(hidden(units) == [True, False], f'fifth removed, sixth kept: the fifth hidden, got {hidden(units)}')
    at = round(units[4].get_actor_location().length(), 2)
    check(at == 0, f'fifth removed, sixth kept: the fifth parked, its weapons with it, got |loc| {at}')
    squad(b, 6, passes=settle, holes=(4,))
    at = round(units[4].get_actor_location().length(), 2)
    check(at == 0, f'later passes leave the empty fifth parked, got |loc| {at}')
    x5 = round(units[5].get_actor_location().x, 2)
    want5 = round(SLOT_STEP * 1.5 + 2.5 * lineup.ROW_STEP_RATIO * SLOT_STEP, 2)
    check(abs(x5 - want5) < 0.05, f'the sixth keeps its own place, want x {want5}, got {x5}')
    picker(b, True)
    units[4].set_actor_hidden_in_game(False)  # the picker previews into the empty fifth
    squad(b, 6, passes=2, holes=(4,))
    expect_row(units, 6, 6, 'picker on the empty fifth: the preview stands in its place in the row')
    picker(b, False)
    squad(b, 6, passes=settle)
    check(hidden(units) == [False, False], f'fifth filled again: both shown, got {hidden(units)}')
    squad(b, 6, passes=settle, holes=(2, 3, 4))
    check(hidden(units) == [True, False],
          f'third, fourth and fifth removed, sixth kept: the fifth hidden, the sixth shown, got {hidden(units)}')

    # A fresh manager: the very first pass records its bases from the authored scales.
    b, units = brain()
    squad(b, 6, passes=1)
    expect(units, 6, BASES, 'first pass at six')
    squad(b, 6, passes=5)
    expect(units, 6, BASES, 'later passes at six leave the row where the first put it')
    unreal.log(f'LINEUP_RESULT ok checks={checks}')
except Exception:
    unreal.log_error(traceback.format_exc())
    unreal.log_error('LINEUP_RESULT failed')
finally:
    for a in actors:
        api.destroy_actor(a)
    # Isolated test asset is outside /SquadSixGF and never included by its DLC cook.
