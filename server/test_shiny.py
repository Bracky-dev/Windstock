import unittest
from unittest.mock import patch

import pb
import protocol
import settings
import shiny
import world


def message(data, field):
    value = pb.get(pb.decode(data), field, pb.WT_LEN)
    if not isinstance(value, bytes):
        raise AssertionError(f"missing message field {field}")
    return value


def display_shiny(data):
    return bool(pb.get(pb.decode(data), 3, pb.WT_VARINT))


class ShinyProtocolTests(unittest.TestCase):
    def setUp(self):
        self.saved_judged = shiny._JUDGED.copy()
        shiny._JUDGED.clear()
        self.config = {"enabled": True, "force": False, "rate": 0.05}
        self.patches = [
            patch.object(shiny._cfg, "get", side_effect=self.get_setting),
            patch.object(shiny, "effective_rate", side_effect=lambda: 1.0 if self.config["force"] else self.config["rate"]),
            patch.object(world, "get_spawn", return_value={"pokemon_id": 25, "lat": 1.0, "lng": 2.0,
                                                          "spawn_id": "spot", "cp": 100}),
            patch.object(world, "bump"),
            patch.object(world, "pokedex_saw"),
            patch.object(world, "get_caught", return_value=None),
            patch.object(world, "deployed_member", return_value=None),
            patch.object(protocol, "wild_uid", side_effect=lambda eid: eid + 1000),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.restore_judged)

    def restore_judged(self):
        shiny._JUDGED.clear()
        shiny._JUDGED.update(self.saved_judged)

    def get_setting(self, section, key, **kwargs):
        if section == "shiny" and key in self.config:
            return self.config[key]
        return settings.DEFAULTS[section][key]

    def check_spawn(self, eid, expected):
        wild = protocol.build_wild_pokemon(eid, 1.0, 2.0, "spot", 25, 1000, cp=100)
        map_pokemon = protocol.build_map_pokemon("spot", eid, 25, 1.0, 2.0, 2000)
        nearby = protocol.build_nearby_pokemon(25, 5, eid)
        encounter = protocol.build_encounter_response(eid, 1000)
        special = protocol.build_special_encounter_response(eid)
        inventory = protocol.build_pokemon_data(25, eid + 1000, 100, extra={"shiny": expected})
        displays = [message(message(wild, 7), 36), message(map_pokemon, 7),
                    message(nearby, 6), message(message(message(encounter, 1), 7), 36),
                    message(message(special, 2), 36), message(inventory, 36)]
        self.assertEqual([display_shiny(d) for d in displays], [expected] * len(displays))
        self.assertEqual(len({pb.get(pb.decode(d), 2, pb.WT_VARINT) for d in displays}), 1)

    def test_normal_and_shiny_across_all_messages(self):
        shiny.set_rate(123, 1.0)
        shiny.set_rate(124, 0.0)
        self.check_spawn(123, True)
        self.check_spawn(124, False)

    def test_rate_force_and_stable_roll(self):
        self.assertEqual(settings.DEFAULTS["shiny"]["rate"], 0.05)
        self.assertFalse(settings.DEFAULTS["shiny"]["force"])
        self.config["rate"] = 0.0
        self.check_spawn(200, False)
        self.config["force"] = True
        self.check_spawn(200, False)  # already judged; no rerolls
        self.check_spawn(201, True)
        shiny.set_rate(201, 0.0)
        self.assertTrue(shiny.is_shiny(201, 25))
        self.config["enabled"] = False
        self.assertFalse(shiny.is_shiny(202, 25))

    def test_lure_map_and_encounter_use_the_same_flag(self):
        self.config["force"] = True
        with patch.object(world, "is_despawned", return_value=False), \
             patch.object(world, "remember_spawn"), \
             patch.object(protocol, "_pick_species", return_value=25), \
             patch.object(protocol, "_pick_cp", return_value=100):
            lure = protocol._lure_pokemon("fort", 1.0, 2.0, {"expires_ms": 100000}, 1000)
        eid = pb.get(pb.decode(lure), 2, pb.WT_64)
        self.assertTrue(display_shiny(message(lure, 7)))
        special = protocol.build_special_encounter_response(eid)
        self.assertTrue(display_shiny(message(message(special, 2), 36)))

    def test_catch_persists_the_encounter_shiny_flag(self):
        shiny.set_rate(321, 1.0)
        with patch.object(world, "pokemon_full", return_value=False), \
             patch.object(world, "take_item", return_value=True), \
             patch.object(world, "berry_mult", return_value=1), \
             patch.object(world, "encounter_uid", return_value=1321), \
             patch.object(world, "add_caught") as add_caught, \
             patch.object(world, "pokedex_is_new", return_value=False), \
             patch.object(world, "pokedex_caught"), \
             patch.object(world, "remove_spawn"), \
             patch.object(world, "drop_bonus_spawn"), \
             patch.object(world, "mark_despawned"), \
             patch.object(world, "current", return_value=type("Player", (), {"username": "test"})()), \
             patch.object(world, "daily_streak", return_value=(0, 0, [], 0, False)), \
             patch.object(world, "add_xp"), patch.object(world, "add_candy"), \
             patch.object(world, "add_stardust"), patch.object(protocol, "fast_catch", return_value=True), \
             patch.object(protocol, "is_ditto", return_value=False), \
             patch.object(protocol, "_score_medals"), \
             patch.object(protocol, "build_capture_award", return_value=(b"", 0)):
            result = protocol.build_catch_pokemon_response(321, 1, True, 1000)
        self.assertEqual(pb.get(pb.decode(result), 1, pb.WT_VARINT), 1)
        self.assertTrue(add_caught.call_args.kwargs["shiny"])

    def test_chance_is_not_limited_to_legacy_model_list(self):
        self.config["rate"] = 0.5
        with patch.object(shiny, "species_with_models", return_value=set()):
            outcomes = [shiny.is_shiny(i, 999) for i in range(500)]
        self.assertTrue(any(outcomes))
        self.assertFalse(all(outcomes))


if __name__ == "__main__":
    unittest.main()
