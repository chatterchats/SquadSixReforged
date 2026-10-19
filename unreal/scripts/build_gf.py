"""Build the Game Feature trial's assets (run by tools/build_gf.sh inside the headless editor).

1. unreal/specs/gf/*.json with ZComAuthoring: the brain component.
2. /SquadSixGF/SquadSixGF, the plugin's GameFeatureData: one AddComponents action that puts the brain
   on every ABitReactorGameState (a modular game state, so it accepts Game Feature components).

Prints SQUADSIXGF_RESULT ok|failed.
"""
import os
from pathlib import Path

import unreal
import zcom_authoring

PLUGIN = "SquadSixGF"
DATA_PATH = f"/{PLUGIN}/{PLUGIN}"
GAME_STATE = "/Script/BitReactorGame.BitReactorGameState"
BRAIN = f"/{PLUGIN}/BP_SquadSixBrain.BP_SquadSixBrain_C"
ADD_COMPONENTS = "/Script/GameFeatures.GameFeatureAction_AddComponents"
ACTION_NAME = "AddBrainToGameState"


def build_data():
    library = unreal.EditorAssetLibrary
    # Updated in place: the Game Feature subsystem holds the data from editor start, so a delete (whose reference
    # scan also crashes on one of the kit's reconstructed classes) can't make way for a new one.
    data = library.load_asset(DATA_PATH) if library.does_asset_exist(DATA_PATH) else None
    if data is None:
        factory = unreal.DataAssetFactory()
        factory.set_editor_property("data_asset_class", unreal.GameFeatureData)
        data = unreal.AssetToolsHelpers.get_asset_tools().create_asset(PLUGIN, f"/{PLUGIN}", unreal.GameFeatureData, factory)
    if data is None:
        unreal.log_error("SQUADSIXGF could not create the GameFeatureData")
        return False
    # Neither the action class, its entry struct nor GameFeatureData.Actions is exposed to Python: build the action by
    # class path and set both lists from text.
    action = unreal.find_object(data, ACTION_NAME) or unreal.new_object(unreal.load_class(None, ADD_COMPONENTS), outer=data, name=ACTION_NAME)
    problem = unreal.ZComAuthoringLibrary.set_property_from_text(
        action, "ComponentList",
        f'((ActorClass="{GAME_STATE}",ComponentClass="{BRAIN}",bClientComponent=True,bServerComponent=True))')
    if problem:
        unreal.log_error(f"SQUADSIXGF ComponentList: {problem}")
        return False
    problem = unreal.ZComAuthoringLibrary.set_property_from_text(data, "Actions", f'("{action.get_path_name()}")')
    if problem:
        unreal.log_error(f"SQUADSIXGF Actions: {problem}")
        return False
    library.save_loaded_asset(data, only_if_is_dirty=False)
    unreal.log(f"SQUADSIXGF data {DATA_PATH}: action {action.get_path_name()}")
    return True


specs = sorted(Path(os.environ["SQUADSIXGF_SPECS"]).glob("*.json"))
ok = bool(specs) and zcom_authoring.build(specs) and build_data()
unreal.log(f"SQUADSIXGF_RESULT {'ok' if ok else 'failed'} ({len(specs)} specs)")
