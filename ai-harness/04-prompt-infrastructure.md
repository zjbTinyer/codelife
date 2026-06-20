# 1.4 — Prompt 基础设施

## 1. Prompt 也是代码

在 AI 工程中，Prompt 已经从"随手写的文本"进化成了**需要版本管理、测试、A/B实验的工程资产**。

```
传统开发: 代码在 Git 里，改了直接部署
Prompt 开发:
  ❌ 在 Claude.ai 聊天框里调 Prompt → 复制粘贴到代码 → 猜它还能不能工作
  ✅ Prompt 在 Git 仓库里 → 版本化 → 自动化测试 → 灰度发布
```

## 2. Prompt 管理的演进

```
Level 1: 硬编码字符串
  prompt = "你是客服助手，帮助用户解决问题。"

Level 2: 配置文件
  prompts/
    customer_service.yaml
    code_review.yaml

Level 3: Prompt 版本库
  有版本号、变更记录、A/B 测试能力的 Prompt 管理

Level 4: PromptOps（Prompt DevOps）
  CI/CD 集成、自动评估、灰度发布、回滚
```

## 3. Prompt 版本管理

### 3.1 Prompt 模板化

```python
from dataclasses import dataclass
from datetime import datetime
import hashlib

@dataclass
class PromptVersion:
    """Prompt 版本"""
    name: str
    version: str           # 语义化版本
    template: str          # Jinja2 模板
    variables: list        # 模板变量
    metadata: dict         # 描述、作者、标签
    created_at: str
    checksum: str          # 内容哈希

class PromptRegistry:
    """Prompt 注册中心 — 类似 Maven/NPM 仓库"""

    def __init__(self, storage_path: str = "./prompts"):
        self.storage_path = storage_path
        self.registry = {}  # name → {version → PromptVersion}

    def register(self, prompt: PromptVersion):
        """注册 Prompt 版本"""
        if prompt.name not in self.registry:
            self.registry[prompt.name] = {}
        self.registry[prompt.name][prompt.version] = prompt
        self._save(prompt)

    def get(self, name: str, version: str = None) -> PromptVersion:
        """获取 Prompt 版本"""
        versions = self.registry.get(name, {})
        if not versions:
            raise ValueError(f"Prompt '{name}' 未注册")

        if version:
            if version not in versions:
                raise ValueError(f"Prompt '{name}' v{version} 不存在")
            return versions[version]

        # 返回最新版本
        latest = sorted(versions.keys(), key=lambda v: v.split("."))[-1]
        return versions[latest]

    def render(self, name: str, version: str = None, **variables) -> str:
        """渲染 Prompt"""
        prompt = self.get(name, version)
        return prompt.template.format(**variables)


# ===== Prompt 定义示例 =====

CUSTOMER_SERVICE_V1 = PromptVersion(
    name="customer_service",
    version="1.0.0",
    template="""## 角色
你是{company_name}的客服助手，工号{agent_id}。

## 能力
{tools_description}

## 规则
1. {rule_1}
2. {rule_2}
3. 回复语气：{tone}

## 上下文
用户：{user_name}
会员等级：{vip_level}""",
    variables=["company_name", "agent_id", "tools_description",
               "rule_1", "rule_2", "tone", "user_name", "vip_level"],
    metadata={
        "author": "zhangsan",
        "description": "客服 Agent 基础 Prompt",
        "tags": ["customer_service", "production"],
        "changelog": "初始版本"
    },
    created_at=datetime.now().isoformat(),
    checksum=hashlib.md5("v1_content".encode()).hexdigest()
)

CUSTOMER_SERVICE_V2 = PromptVersion(
    name="customer_service",
    version="1.1.0",
    template="""## 角色
你是{company_name}的客服助手，工号{agent_id}。

## 能力
{tools_description}

## 规则
1. {rule_1}
2. {rule_2}
3. 退款金额 > {max_auto_refund}元 → 升级人工审核
4. 回复语气：{tone}
5. 每次回复末尾加上满意度评分邀请

## 上下文
用户：{user_name}
会员等级：{vip_level}
历史投诉：{complaint_count}次""",
    variables=["company_name", "agent_id", "tools_description",
               "rule_1", "rule_2", "max_auto_refund", "tone",
               "user_name", "vip_level", "complaint_count"],
    metadata={
        "author": "zhangsan",
        "description": "客服 Agent Prompt V2 — 增加退款限制和满意度",
        "tags": ["customer_service", "production"],
        "changelog": "新增: 退款金额限制、满意度评分、用户投诉历史"
    },
    created_at=datetime.now().isoformat(),
    checksum=hashlib.md5("v2_content".encode()).hexdigest()
)
```

### 3.2 变更审计

```python
class PromptAuditLog:
    """Prompt 变更审计"""

    def __init__(self):
        self.changes = []

    def record_change(self, prompt_name: str,
                      from_version: str, to_version: str,
                      diff: str, author: str, reason: str):
        """记录变更"""
        self.changes.append({
            "timestamp": datetime.now().isoformat(),
            "prompt": prompt_name,
            "from": from_version,
            "to": to_version,
            "diff": diff,
            "author": author,
            "reason": reason,
        })

    def generate_report(self, prompt_name: str) -> str:
        """生成变更报告"""
        relevant = [c for c in self.changes if c["prompt"] == prompt_name]

        report = f"# Prompt 变更报告 — {prompt_name}\n\n"
        for c in relevant:
            report += f"""## {c['timestamp']} | {c['from']} → {c['to']}
- **作者**: {c['author']}
- **原因**: {c['reason']}
- **变更**:
```diff
{c['diff']}
```

"""
        return report
```

## 4. A/B 测试

```python
import random
import hashlib

class PromptABTest:
    """Prompt A/B 测试框架"""

    def __init__(self, experiment_name: str):
        self.name = experiment_name
        self.variants = {}  # "control" → prompt, "variant_a" → prompt

    def add_variant(self, name: str, prompt: str, traffic_pct: float):
        """添加测试变体"""
        self.variants[name] = {
            "prompt": prompt,
            "traffic_pct": traffic_pct
        }

    def assign(self, user_id: str) -> str:
        """为用户分配变体（一致性哈希保证同一用户总是同一变体）"""
        # 一致性哈希
        hash_val = int(hashlib.md5(user_id.encode()).hexdigest(), 16) % 100

        cumulative = 0
        for name, config in self.variants.items():
            cumulative += config["traffic_pct"]
            if hash_val < cumulative:
                return name, config["prompt"]

        # 默认返回第一个
        first = list(self.variants.keys())[0]
        return first, self.variants[first]["prompt"]


# ===== 使用示例 =====

ab_test = PromptABTest("refund_prompt_v2")

ab_test.add_variant(
    "control",
    "你是客服助手。处理退款时，先确认订单状态再操作。",
    traffic_pct=50.0
)
ab_test.add_variant(
    "variant_a",
    "你是客服助手。处理退款时，先共情用户（'我理解您的感受'），再确认订单状态，然后操作。",
    traffic_pct=50.0
)

# 在 Agent 中使用
variant_name, prompt = ab_test.assign(user_id)

# 记录实验结果
analytics.track("prompt_assigned", {
    "experiment": "refund_prompt_v2",
    "variant": variant_name,
    "user_id": user_id
})
```

### A/B 实验结果分析

```python
class ABTestAnalyzer:
    """A/B 测试结果分析"""

    def __init__(self, experiment_name: str):
        self.name = experiment_name
        self.results = {}  # variant → [{user_id, metric_1, metric_2, ...}]

    def add_result(self, variant: str, user_id: str, metrics: dict):
        """添加一次实验结果"""
        if variant not in self.results:
            self.results[variant] = []
        self.results[variant].append({"user_id": user_id, **metrics})

    def analyze(self) -> dict:
        """分析各变体性能"""
        import statistics

        analysis = {}
        for variant, results in self.results.items():
            if not results:
                continue

            # 关键指标
            success_rates = [r.get("success", 0) for r in results]
            latencies = [r.get("latency_ms", 0) for r in results]
            user_satisfaction = [r.get("satisfaction", 0) for r in results]

            analysis[variant] = {
                "sample_size": len(results),
                "success_rate": sum(success_rates) / len(success_rates),
                "avg_latency": statistics.mean(latencies),
                "avg_satisfaction": statistics.mean(user_satisfaction),
            }

        # 对比（假设 control 是基准）
        if "control" in analysis and len(analysis) > 1:
            baseline = analysis["control"]
            for variant, stats in analysis.items():
                if variant == "control":
                    continue
                stats["vs_control"] = {
                    "success_delta": stats["success_rate"] - baseline["success_rate"],
                    "latency_delta": stats["avg_latency"] - baseline["avg_latency"],
                    "satisfaction_delta": stats["avg_satisfaction"] - baseline["avg_satisfaction"],
                }

        return analysis
```

## 5. Prompt 编译与优化

### 5.1 Prompt 编译（DSPy 思想）

```python
class PromptCompiler:
    """自动优化 Prompt — 受 DSPy 启发"""

    def __init__(self):
        self.optimization_history = []

    def compile(self, task_description: str, training_examples: list,
                base_prompt: str, metric_func: callable,
                iterations: int = 10) -> str:
        """自动迭代优化 Prompt"""

        best_prompt = base_prompt
        best_score = 0.0

        for i in range(iterations):
            # 在当前 Prompt 上评估
            scores = []
            failures = []

            for example in training_examples:
                output = self._run_prompt(best_prompt, example["input"])
                score = metric_func(output, example["expected"])
                scores.append(score)

                if score < 0.7:  # 失败的例子
                    failures.append(example)

            avg_score = sum(scores) / len(scores)

            # 如果比之前好，更新
            if avg_score > best_score:
                best_score = avg_score

            # 用失败的例子来改进 Prompt
            if failures:
                improvement = self._suggest_improvement(
                    best_prompt, task_description, failures
                )
                best_prompt = improvement

            print(f"[Iteration {i+1}] Score: {avg_score:.3f} | Best: {best_score:.3f}")

        return best_prompt

    def _suggest_improvement(self, current_prompt: str,
                             task: str, failures: list) -> str:
        """让 LLM 建议 Prompt 改进"""
        failures_text = "\n".join(
            f"输入: {f['input']}\n期望: {f['expected']}" for f in failures[:3]
        )

        response = anthropic.Anthropic().messages.create(
            model="claude-sonnet-4-6",
            max_tokens=500,
            system="你是 Prompt 优化专家。分析失败案例，改进 Prompt 使其更加明确和有效。",
            messages=[{
                "role": "user",
                "content": f"""当前 Prompt:
{current_prompt}

任务: {task}

失败案例:
{failures_text}

请改进 Prompt，重点解决以上失败案例中的问题。直接返回改进后的 Prompt 全文。"""
            }]
        )
        return response.content[0].text

    def _run_prompt(self, prompt: str, input_text: str) -> str:
        response = anthropic.Anthropic().messages.create(
            model="claude-haiku-4-5",  # 用快模型降低成本
            max_tokens=256,
            system=prompt,
            messages=[{"role": "user", "content": input_text}]
        )
        return response.content[0].text
```

## 6. Prompt 安全存储

```python
import os
from cryptography.fernet import Fernet

class PromptVault:
    """Prompt 安全存储 — 保护敏感 Prompt 不被泄露"""

    def __init__(self, encryption_key: str = None):
        self.key = encryption_key or os.getenv("PROMPT_ENCRYPTION_KEY")
        self.cipher = Fernet(self.key.encode()) if self.key else None

    def encrypt(self, prompt: str) -> str:
        """加密 Prompt"""
        if not self.cipher:
            raise ValueError("未配置加密密钥")
        return self.cipher.encrypt(prompt.encode()).decode()

    def decrypt(self, encrypted_prompt: str) -> str:
        """解密 Prompt"""
        if not self.cipher:
            raise ValueError("未配置加密密钥")
        return self.cipher.decrypt(encrypted_prompt.encode()).decode()

    def store(self, name: str, prompt: str, encrypt: bool = True):
        """安全存储 Prompt"""
        content = self.encrypt(prompt) if encrypt else prompt
        with open(f"prompts/{name}.enc", "w") as f:
            f.write(content)

    def load(self, name: str, encrypted: bool = True) -> str:
        """安全加载 Prompt"""
        with open(f"prompts/{name}.enc") as f:
            content = f.read()
        return self.decrypt(content) if encrypted else content
```

## 7. 目录结构最佳实践

```
prompts/
├── README.md                    # Prompt 使用说明
├── registry.json                # Prompt 注册信息
├── versions/                    # 按版本管理
│   ├── customer_service/
│   │   ├── v1.0.0.txt
│   │   ├── v1.1.0.txt
│   │   └── CHANGELOG.md
│   └── code_review/
│       ├── v1.0.0.txt
│       └── CHANGELOG.md
├── templates/                   # 可复用的 Prompt 片段
│   ├── safety_rules.txt
│   ├── output_format.txt
│   └── role_definitions/
│       ├── expert.yaml
│       └── friendly.yaml
├── tests/                       # Prompt 测试用例
│   ├── test_customer_service.py
│   └── test_code_review.py
├── experiments/                 # A/B 测试配置
│   └── refund_tone_test.yaml
└── prompts.yaml                 # 主配置文件
```

## 8. 总结

```
Prompt Engineering → Prompt Infrastructure

核心理念:
1. Prompt 是代码 → 版本管理、代码审查、测试
2. Prompt 是配置 → 环境分离、动态注入
3. Prompt 需评估 → 每次改动都要跑测试集
4. Prompt 可实验 → A/B 测试验证效果
5. Prompt 是资产 → 加密存储、访问控制

Java 类比:
  Prompt 模板   = Thymeleaf / Freemarker 模板
  Prompt 版本   = Maven 依赖版本管理
  Prompt 注册中心 = Nacos / Apollo 配置中心
  Prompt A/B测试 = 灰度发布 / 特性开关
```
