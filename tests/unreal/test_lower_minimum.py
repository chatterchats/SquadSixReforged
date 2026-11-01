"""Execute LowerMinimum's compiled graph on mission definitions built in the editor.

The rule is the game-independent part: the required cast plus one, never raised. It does not establish that the game's
squad select honours the lowered value; that takes the shipping game (docs/live-tests.md).
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
import gf

checks = 0


def check(ok, label):
    global checks
    checks += 1
    unreal.log(f'MINIMUM_TEST {"ok" if ok else "FAIL"}: {label}')
    assert ok, label


def mission(minimum, cast):
    m = unreal.new_object(unreal.BrunoMissionData)
    m.set_editor_property('MinSquadSize', minimum)
    m.set_editor_property('CharacterRequirements', [unreal.CharacterRequirement() for _ in range(cast)])
    return m


try:
    path = '/Game/SquadSixTests/BP_LowerMinimumFixture'
    spec = dict(kind='blueprint', path=path, parent='/Script/Engine.ActorComponent',
                variables=[dict(name='Lowered', type='int', default='0')], functions=[gf.lower_minimum()])
    dest = repo / 'dist/gf-tests'
    dest.mkdir(parents=True, exist_ok=True)
    source = dest / 'lower-minimum-fixture.json'
    source.write_text(json.dumps(spec))
    assert zcom_authoring.build([source])
    cls = unreal.EditorAssetLibrary.load_blueprint_class(path)
    brain = unreal.new_object(cls)

    # (shipped minimum, required cast, expected minimum, what it stands for)
    for minimum, cast, expected, label in (
            (4, 0, 1, 'a skirmish with no required cast'),
            (3, 0, 1, 'a three-operator mission with no required cast (SK_Kaller_030)'),
            (4, 1, 2, 'a story mission requiring Hawks'),
            (3, 1, 2, 'a three-operator story mission requiring Hawks (Deep Cover)'),
            (4, 2, 3, 'a hero mission requiring Hawks and a companion'),
            (4, 3, 4, 'HM_TrickLuco_020, already at its cast plus one'),
            (1, 1, 1, 'a Hawks-only mission already at one is not raised'),
            (1, 0, 1, 'a mission already at one with no required cast')):
        m = mission(minimum, cast)
        brain.call_method('LowerMinimum', (m,))
        check(m.get_editor_property('MinSquadSize') == expected, f'{minimum} -> {expected}: {label}')

    brain = unreal.new_object(cls)
    m = mission(4, 0)
    for _ in range(3):
        brain.call_method('LowerMinimum', (m,))
    check(brain.get_editor_property('Lowered') == 1, 'repeat sweeps change a mission once')
    m = mission(4, 3)
    brain.call_method('LowerMinimum', (m,))
    check(brain.get_editor_property('Lowered') == 1, 'an unchanged mission does not count')
    unreal.log(f'MINIMUM_RESULT ok checks={checks}')
except Exception:
    unreal.log_error(traceback.format_exc())
    unreal.log_error('MINIMUM_RESULT failed')
