clear; close all; clc;

addpath(genpath('Utils\'));

femur_stl = stlLoad('CT_Femur_editedFlipped_scaled.stl');
tibia_stl = stlLoad('CT_Tibia_editedFlipped_scaled.stl');
ezpatch(femur_stl);
ezpatch(tibia_stl);