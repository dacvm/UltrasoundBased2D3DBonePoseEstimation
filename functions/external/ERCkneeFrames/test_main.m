clear; close all; clc;

addpath(genpath('Utils\'));

filepath = 'D:\Documents\BELANDA\SonoSkin\data\CTdata-KneePhantom\NoStudyDescription\meshes\bones';
filename_femur = 'Femur_1_Smoothed_Reduced.stl';
filename_tibia = 'Tibia_1_Smoothed_Reduced.stl';
femur_str = fullfile(filepath, filename_femur);
tibia_str = fullfile(filepath, filename_tibia);

[ acs,stlData,DiagInfo ] = ERCkneeReferenceFrames( femur_str, [] , tibia_str);
femur_stl = stlLoad(femur_str);
tibia_stl = stlLoad(tibia_str);
ezpatch(femur_stl);
ezpatch(tibia_stl);

%%

% [acs,~,diag] = ERCkneeReferenceFrames(meshfem,meshpat,meshtib);
acs.f.R = [acs.f.X; acs.f.Y; acs.f.Z];
acs.t.R = [acs.t.X; acs.t.Y; acs.t.Z];

plotCoords(acs.f.R', acs.f.origin);
plotCoords(acs.t.R', acs.t.origin);

tfangs = findang_groodsuntay_style(acs.f.R, acs.t.R,'right');
tftrans = (acs.t.origin - acs.f.origin)*acs.f.R';

% Directions:
% Flexion = +, Extension = -
% Abduction(Valgus)= +, Adduction (Varus) = -
% Exorotation = +, Endorotation = -
% + is anterior position of the tibia relative to the femur.
% + is proximal position of the tibia relative to the femur.
% +is medial(after wefliptheaxisfortherightside

FTPKin.Flexion = tfangs(:,1);
FTPKin.AdAbdduction = tfangs(:,2);
FTPKin.EndoExo = tfangs(:,3);
FTPKin.APtrans = tftrans(:,1); % + is anterior translation of the tibia/patella relative to the femur.
FTPKin.PDtrans = tftrans(:,2); % + is proximal translation of the tibia/patella relative to the femur.
FTPKin.MLtrans = tftrans(:,3);
%%The side is right so flip the ML values to make sure that translations towards the medial side are positive.
FTP.MLtrans = -FTPKin.MLtrans;

%%
timestamp = datestr(datetime('now'), 'yyyymmdd-HHMMSS');
[~, name, ~] = fileparts(femur_str);
str = sprintf('%s_%s.mat', name, timestamp);
save(str, 'acs');