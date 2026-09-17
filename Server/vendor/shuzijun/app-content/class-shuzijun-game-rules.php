<?php

/** Pure, bounded interpreter for the bundled game rules. No WordPress, JS or eval. */
final class Shuzijun_Game_Rules {
    const VERSION = 'life-v1';
    const FILE_SHA256 = '1ee7357cbd5018f84618ea610e8c8b648b9857ce22f05d91c91eb052cd36fdf1';
    const STAT_KEYS = array('贪腐', '财富', '民心', '健康', '人脉', '事业', '廉洁', '声望');
    private $rules;
    private $origins;
    private $endings;

    public static function bundled() {
        static $instance = null;
        if ($instance instanceof self) { return $instance; }
        $path = __DIR__ . '/game-rules-v1.json';
        if (!is_file($path) || is_link($path) || filesize($path) > 524288) {
            throw new RuntimeException('game_rules_unavailable');
        }
        $bytes = file_get_contents($path);
        if (!is_string($bytes) || !hash_equals(self::FILE_SHA256, hash('sha256', $bytes))) {
            throw new RuntimeException('game_rules_integrity_failed');
        }
        $rules = json_decode($bytes, true, 32, JSON_THROW_ON_ERROR);
        $instance = new self($rules);
        return $instance;
    }

    /** Public for isolated fixtures; HTTP handlers use only bundled(). */
    public function __construct($rules) {
        $this->require_valid(is_array($rules) && ($rules['version'] ?? '') === self::VERSION);
        $this->require_valid(preg_match('/^[a-f0-9]{64}$/D', (string) ($rules['rulesHash'] ?? '')) === 1);
        $this->require_valid(($rules['maxChoices'] ?? null) === 108);
        $this->require_valid(is_array($rules['baseStats'] ?? null));
        $keys = array_keys($rules['baseStats']);
        $expected = self::STAT_KEYS;
        sort($keys); sort($expected);
        $this->require_valid($keys === $expected);
        foreach ($rules['baseStats'] as $value) { $this->require_valid($this->number($value)); }
        $this->require_valid(is_array($rules['origins'] ?? null) && count($rules['origins']) === 6);
        $this->origins = array();
        foreach ($rules['origins'] as $origin) {
            $this->require_valid(is_array($origin) && $this->identifier($origin['id'] ?? null)
                && $this->text($origin['name'] ?? null, 40) && is_array($origin['bonus'] ?? null));
            $this->require_valid(!isset($this->origins[$origin['id']]));
            $this->validate_delta($origin['bonus']);
            $this->origins[$origin['id']] = $origin;
        }
        $this->require_valid(is_array($rules['events'] ?? null)
            && array_is_list($rules['events']) && count($rules['events']) === 108);
        foreach ($rules['events'] as $event) {
            $this->require_valid(is_array($event) && $this->text($event['phase'] ?? null, 80)
                && is_array($event['options'] ?? null) && array_is_list($event['options'])
                && count($event['options']) === 4);
            foreach ($event['options'] as $option) {
                $this->require_valid(is_array($option) && is_array($option['delta'] ?? null));
                $this->validate_delta($option['delta']);
                $this->require_valid(($option['flag'] ?? null) === null
                    || $this->text($option['flag'], 100));
            }
        }
        $this->require_valid(is_array($rules['endings'] ?? null)
            && array_is_list($rules['endings']) && count($rules['endings']) === 28);
        $this->endings = array();
        foreach ($rules['endings'] as $ending) {
            $this->require_valid(is_array($ending) && $this->identifier($ending['id'] ?? null)
                && $this->text($ending['title'] ?? null, 80)
                && in_array($ending['grade'] ?? null, array('S', 'A', 'B', 'C', 'D', 'F'), true));
            $this->require_valid(!isset($this->endings[$ending['id']]));
            $this->validate_ast($ending['check'] ?? null, 0);
            $this->endings[$ending['id']] = $ending;
        }
        $this->require_valid(is_array($rules['immediateEnds'] ?? null)
            && array_is_list($rules['immediateEnds']) && count($rules['immediateEnds']) === 3);
        foreach ($rules['immediateEnds'] as $ending) {
            $this->require_valid(isset($this->endings[$ending['id'] ?? '']));
            $this->validate_ast($ending['check'] ?? null, 0);
        }
        $this->require_valid(is_array($rules['derived'] ?? null));
        $this->validate_formula($rules['derived']['integrity'] ?? null, array('贪腐', '财富'));
        $this->validate_formula($rules['derived']['reputation'] ?? null, array('事业', '民心', '廉洁'));
        $this->validate_formula($rules['score'] ?? null, array('事业', '民心', '财富', '健康', '人脉', '贪腐'));
        $this->require_valid(($rules['derived']['integrity']['base'] ?? null) === 100
            && ($rules['derived']['integrity']['min'] ?? null) === 0
            && ($rules['derived']['integrity']['max'] ?? null) === 100
            && ($rules['derived']['reputation']['round'] ?? '') === 'js-Math.round'
            && ($rules['score']['round'] ?? '') === 'js-Math.round'
            && ($rules['score']['min'] ?? null) === -16777216
            && ($rules['score']['max'] ?? null) === 16777215);
        $this->require_valid(is_array($rules['score']['gradeBase'] ?? null));
        foreach (array('S', 'A', 'B', 'C', 'D', 'F') as $grade) {
            $this->require_valid(is_int($rules['score']['gradeBase'][$grade] ?? null));
        }
        $this->rules = $rules;
    }

    public function hash() { return $this->rules['rulesHash']; }

    public function origin_name($id) { return $this->origins[$id]['name'] ?? null; }

    public function ending_title($id) { return $this->endings[$id]['title'] ?? null; }

    public function replay($origin_id, $choices) {
        if (!is_string($origin_id) || !isset($this->origins[$origin_id])
            || !is_array($choices) || !array_is_list($choices)
            || count($choices) < 1 || count($choices) > 108) {
            throw new InvalidArgumentException('game_choices_invalid');
        }
        foreach ($choices as $choice) {
            if (!is_int($choice) || $choice < 0 || $choice > 3) {
                throw new InvalidArgumentException('game_choices_invalid');
            }
        }
        $stats = $this->rules['baseStats'];
        $this->apply_delta($stats, $this->origins[$origin_id]['bonus']);
        $flags = array();
        $current = 0;
        $answered = 0;
        $phase = '试用期';
        $ending = null;
        foreach ($choices as $choice) {
            if ($ending !== null || $current >= 108) {
                throw new InvalidArgumentException('game_choices_after_ending');
            }
            $event = $this->rules['events'][$current];
            $option = $event['options'][$choice];
            $this->apply_delta($stats, $option['delta']);
            if (!empty($option['flag'])) {
                $flag = $option['flag'];
                $flags[$flag] = ($flags[$flag] ?? 0) + 1;
            }
            $integrity = $this->rules['derived']['integrity'];
            $stats['廉洁'] = $this->clamp($this->weighted($integrity, $stats, $integrity['base']), 0, 100);
            $stats['声望'] = $this->js_round($this->weighted($this->rules['derived']['reputation'], $stats));
            $phase = $event['phase'];
            foreach ($this->rules['immediateEnds'] as $candidate) {
                if ($this->matches($candidate['check'], $stats)) {
                    $ending = $this->endings[$candidate['id']];
                    break;
                }
            }
            // Original immediate endings happen BEFORE nextEvent increments.
            if ($ending !== null) { continue; }
            $current++;
            $answered++;
            if ($current === 108) {
                foreach ($this->rules['endings'] as $candidate) {
                    if ($this->matches($candidate['check'], $stats)) {
                        $ending = $candidate;
                        break;
                    }
                }
                if ($ending === null) { $ending = $this->rules['endings'][27]; }
            }
        }
        if ($ending === null) { throw new InvalidArgumentException('game_run_incomplete'); }
        $score = $this->rules['score'];
        $value = $score['gradeBase'][$ending['grade']]
            + $this->js_round($this->weighted($score, $stats));
        return array(
            'rulesVersion' => self::VERSION,
            'rulesHash' => $this->hash(),
            'origin' => $origin_id,
            'originName' => $this->origin_name($origin_id),
            'score' => (int) $this->clamp($value, $score['min'], $score['max']),
            'endingID' => $ending['id'],
            'endingTitle' => $ending['title'],
            'answered' => count($choices),
            'currentIdx' => $current,
            'totalAnswered' => $answered,
            'phase' => $phase,
            'stats' => $stats,
            'flags' => $flags,
        );
    }

    private function apply_delta(&$stats, $delta) {
        foreach ($delta as $key => $value) {
            // Unknown original attributes (精力/风险/家庭) stay ignored.
            if (array_key_exists($key, $stats)) { $stats[$key] = $this->clamp($stats[$key] + $value, 0, 100); }
        }
    }

    private function weighted($formula, $stats, $value = 0) {
        foreach ($formula['order'] as $key) { $value += $formula['weights'][$key] * $stats[$key]; }
        return $value;
    }

    private function js_round($value) { return (int) floor($value + 0.5); }
    private function clamp($value, $min, $max) { return max($min, min($max, $value)); }
    private function number($value) { return (is_int($value) || is_float($value)) && is_finite((float) $value); }
    private function identifier($value) { return is_string($value) && preg_match('/^[a-z][a-z0-9_]{0,63}$/D', $value) === 1; }
    private function text($value, $max) { return is_string($value) && preg_match('/^.{1,' . $max . '}$/usD', $value) === 1; }
    private function require_valid($condition) { if (!$condition) { throw new RuntimeException('game_rules_invalid'); } }

    private function validate_delta($delta) {
        $this->require_valid(count($delta) <= 16);
        foreach ($delta as $key => $value) {
            $this->require_valid($this->text($key, 30) && $this->number($value) && abs($value) <= 100);
        }
    }

    private function validate_formula($formula, $order) {
        $this->require_valid(is_array($formula) && ($formula['order'] ?? null) === $order
            && is_array($formula['weights'] ?? null) && count($formula['weights']) === count($order));
        foreach ($order as $key) { $this->require_valid($this->number($formula['weights'][$key] ?? null)); }
    }

    private function validate_ast($node, $depth) {
        $this->require_valid(is_array($node) && $depth <= 8 && is_string($node['op'] ?? null));
        if ($node['op'] === 'true') { $this->require_valid(count($node) === 1); return; }
        if (in_array($node['op'], array('and', 'or'), true)) {
            $this->require_valid(count($node) === 2 && is_array($node['args'] ?? null)
                && array_is_list($node['args']) && count($node['args']) >= 2 && count($node['args']) <= 16);
            foreach ($node['args'] as $arg) { $this->validate_ast($arg, $depth + 1); }
            return;
        }
        $this->require_valid(count($node) === 3
            && in_array($node['op'], array('gte', 'gt', 'lte', 'lt', 'eq', 'ne'), true)
            && in_array($node['stat'] ?? null, self::STAT_KEYS, true)
            && $this->number($node['value'] ?? null));
    }

    private function matches($node, $stats) {
        switch ($node['op']) {
            case 'true': return true;
            case 'and':
                foreach ($node['args'] as $arg) { if (!$this->matches($arg, $stats)) { return false; } }
                return true;
            case 'or':
                foreach ($node['args'] as $arg) { if ($this->matches($arg, $stats)) { return true; } }
                return false;
            case 'gte': return $stats[$node['stat']] >= $node['value'];
            case 'gt': return $stats[$node['stat']] > $node['value'];
            case 'lte': return $stats[$node['stat']] <= $node['value'];
            case 'lt': return $stats[$node['stat']] < $node['value'];
            case 'eq': return $stats[$node['stat']] == $node['value'];
            case 'ne': return $stats[$node['stat']] != $node['value'];
        }
        throw new RuntimeException('game_rules_invalid');
    }
}
