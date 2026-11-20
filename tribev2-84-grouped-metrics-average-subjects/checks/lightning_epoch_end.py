"""End-to-end check of BrainModule.on_val_or_test_epoch_end through a real
Lightning validation loop, with the real neuraltrain GroupedMetric
(OnlinePearsonCorr, as configured in tribev2/grids/defaults.py).

Only validation_step is replaced (it feeds synthetic predictions, targets and
subject ids to the metric); the epoch-end hook, the metric and the logging are
the code under test. Prints one JSON line per case.
"""
import json
import sys
import warnings

import lightning.pytorch as pl
import torch
from neuraltrain.metrics.metrics import GroupedMetric
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

from tribev2.pl_module import BrainModule

warnings.filterwarnings("ignore")


class Probe(BrainModule):
    def validation_step(self, batch, batch_idx):
        y_pred, y_true, subject = batch
        self.metrics["val/subj_pearson"].update(y_pred, y_true, groups=subject)


def run(case, mapping, subjects):
    torch.manual_seed(0)
    n = len(subjects)
    y_true = torch.randn(n, 4)
    y_pred = y_true + 0.5 * torch.randn(n, 4)
    module = Probe(
        model=nn.Linear(1, 1),
        loss=nn.MSELoss(),
        optim_config=None,
        metrics=nn.ModuleDict(
            {"val/subj_pearson": GroupedMetric("OnlinePearsonCorr", {"dim": 0})}
        ),
        config={"data.subject_id.predefined_mapping": mapping},
    )
    loader = DataLoader(
        TensorDataset(y_pred, y_true, torch.tensor(subjects)), batch_size=8
    )
    trainer = pl.Trainer(
        accelerator="cpu", logger=False, enable_progress_bar=False,
        enable_model_summary=False, enable_checkpointing=False,
    )
    try:
        trainer.validate(module, dataloaders=loader, verbose=False)
    except Exception as exc:  # report, do not hide
        return {"case": case, "ok": False, "error": f"{type(exc).__name__}: {exc}"}
    logged = sorted(k for k in trainer.callback_metrics if k.startswith("val/subj_pearson/"))
    return {"case": case, "ok": True, "logged": logged}


if __name__ == "__main__":
    results = [
        run("named subjects (predefined_mapping set)",
            {"sub-01": 0, "sub-02": 1}, [0] * 16 + [1] * 16),
        run("average_subjects=True (predefined_mapping None)", None, [0] * 32),
    ]
    for r in results:
        print(json.dumps(r))
    sys.exit(0 if all(r["ok"] for r in results) else 1)
