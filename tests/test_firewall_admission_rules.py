import unittest
from pathlib import Path


HOSTFORGE_SCRIPT = (Path(__file__).resolve().parents[1] / "hostforge.sh").read_text(encoding="utf-8")


class FirewallAdmissionRuleTests(unittest.TestCase):
    def test_verified_and_first_fifty_pending_players_pass_admission(self):
        verified_return = 'iptables -t raw -A "$admission_chain" -m set --match-set "$verified_set" src -j RETURN'
        pending_return = 'iptables -t raw -A "$admission_chain" -m set --match-set "$pending_set" src -j RETURN'
        pending_add = 'iptables -t raw -A "$admission_chain" -j SET --add-set "$pending_set" src --exist'
        final_drop = 'iptables -t raw -A "$admission_chain" -j DROP'
        admission_rules = [
            line.strip()
            for line in HOSTFORGE_SCRIPT.splitlines()
            if line.strip().startswith('sudo_run iptables -t raw -A "$admission_chain"')
        ]

        self.assertEqual(
            admission_rules,
            [
                f"sudo_run {verified_return}",
                f"sudo_run {pending_return}",
                f"sudo_run {pending_add}",
                f"sudo_run {pending_return}",
                f"sudo_run {final_drop}",
            ],
        )

    def test_pending_set_is_bounded_to_fifty_with_thirty_second_timeout(self):
        self.assertIn('DEFAULT_FIREWALL_PENDING_MAX="${HF_FIREWALL_PENDING_MAX:-50}"', HOSTFORGE_SCRIPT)
        self.assertIn('DEFAULT_FIREWALL_PENDING_TIMEOUT="${HF_FIREWALL_PENDING_TIMEOUT:-30}"', HOSTFORGE_SCRIPT)
        self.assertIn(
            'ipset create "$pending_set" hash:ip family inet hashsize 64 '
            'maxelem "$pending_max" timeout "$pending_timeout" counters -exist',
            HOSTFORGE_SCRIPT,
        )

    def test_only_allowed_unverified_packets_renew_pending_lease(self):
        renewal = (
            'iptables -t raw -A "$chain_name" -m set ! --match-set "$verified_set" src '
            '-j SET --add-set "$pending_set" src --exist'
        )
        player_tracking = 'iptables -t raw -A "$chain_name" -m set --match-set "$set_name" src -j RETURN'

        self.assertIn(renewal, HOSTFORGE_SCRIPT)
        self.assertLess(HOSTFORGE_SCRIPT.index(renewal), HOSTFORGE_SCRIPT.index(player_tracking))

    def test_enforcement_remains_after_admission(self):
        direct_blacklist_drop = (
            'iptables -t raw -A "$ingress_chain" -m set '
            '--match-set "$blacklist_set" src -j DROP'
        )
        geo_jump = 'iptables -t raw -A "$ingress_chain" -j "$geo_chain"'
        admission_jump = 'iptables -t raw -A "$ingress_chain" -j "$admission_chain"'
        rate_limit_jump = 'iptables -t raw -A "$ingress_chain" -j "$blacklist_chain"'
        tracking_jump = 'iptables -t raw -A "$ingress_chain" -j "$chain_name"'

        self.assertLess(HOSTFORGE_SCRIPT.index(admission_jump), HOSTFORGE_SCRIPT.index(direct_blacklist_drop))
        self.assertLess(HOSTFORGE_SCRIPT.index(direct_blacklist_drop), HOSTFORGE_SCRIPT.index(geo_jump))
        self.assertLess(HOSTFORGE_SCRIPT.index(geo_jump), HOSTFORGE_SCRIPT.index(rate_limit_jump))
        self.assertLess(HOSTFORGE_SCRIPT.index(rate_limit_jump), HOSTFORGE_SCRIPT.index(tracking_jump))


if __name__ == "__main__":
    unittest.main()
