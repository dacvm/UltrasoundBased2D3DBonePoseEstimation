clear, clc

%% Opt Script
addpath('param');
addpath('Library');

%% Overal options
resume = 0;
mat_restart = 1;
tot_run = 10;
functionName = 'IID_OptFun_inv';

%% Setting resume options
% Second time (after Matlab restart) or in case of a manual restart
if exist('restart.mat','file') == 2
    resume = 0;
    load('OptData/OptSaver.mat')
    delete('restart.mat')
elseif resume == 1
    load('OptData/cmaes_var.mat','out');x = out.solutions.bestever.x;
    
    % Trial to build model in case of restart
    val = feval(functionName,x);
    disp(['Bestever until now: ',num2str(val)]); clear out val;
    load('OptData/OptSaver.mat')
else
    % In case of real start
    i_opts = 1;
    %% Restart check
    choice = questdlg('Do you really want to start a new Simulation run?', ...
        'Restart?', ...
        'Yes, make backup','Yes, no backup','No','No');
    switch choice
        case('Yes, make backup')
            copyfile('Simulations','Simulations_old')
            rmdir('Simulations','s'); mkdir('Simulations');
            fopen('Simulations/keep_folder.txt','w');fclose('all');
        case('Yes, no backup')
            rmdir('Simulations','s'); mkdir('Simulations')
            fopen('Simulations/keep_folder.txt','w');fclose('all');
        otherwise
            return
    end
end

while i_opts <= tot_run
    %% Set x_zero to param or to previously found best
    if i_opts == 1
        load('param_V74_2D.mat');
        copyfile('DataSets/SFM_AS_Set13CombAllnIns_hLoad','HumanData')
        x_zero = param;
    else
        load(['Simulations/Sim',num2str(i_opts-1),'/cmaes_var.mat'],'out')
        x_zero = out.solutions.bestever.x; clear out;
    end
    
    %% Build Model
    if strcmp(functionName,'IID_OptFun_hyb')
        init_val = feval('IID_OptFun_for',x_zero);
        disp(['Initial value forward: ',num2str(init_val)]); clear val;
    end
    
    %Resume
    if exist('resume','var')
        % Only set to one on first run
        opts.resume = resume;
        clear resume;
    else
        opts.resume = 0;
    end
    
    % Overal save of options
    if opts.resume == 0
        % Outcome list
        val_list = [];
    end
    
    %% Manual Options
    % Parpool settings
    opts.ParforRun = 1;
    opts.ParforWorkers = 20;
    
    if opts.ParforRun == 1
        p = gcp;
    end
    
    % Other options
    opts.Noise.on = 0;
    opts.PopSize = 20;
    opts.SaveFilename = 'OptData/cmaes_var.mat';
    opts.LogFilenamePrefix ='OptData/cmaes_out';
    opts.LogPlot = 0;
    opts.MaxFunEvals = 16000;
    %     opts.LBounds = [0 -10 0 0.9 1.2]';
    %     opts.UBounds = [10 0 10 1.3 1.5]';
    
    %% Sigma list
    sigma_list = ones(27,1)*0.2;
    
    %% Optimalization
    save('OptData/OptSaver.mat','val_list','i_opts')
    [xmin,fmin,counteval,stopflag,out,bestever] = cmaes_parfor(functionName,x_zero,sigma_list,opts)
    
    %% Saving Optimization
    copyfile('OptData',['Simulations/Sim',num2str(i_opts)])
    
    %% Breaking or continuing
    if strcmp(stopflag{:},'manual')
        break;
    else
        i_opts = i_opts+1;
    end
    
    if i_opts < tot_run && mat_restart == 1
        restart_now = 1;
        save('restart.mat','restart_now')
        save('OptData/OptSaver.mat','val_list','i_opts')
        quit
    end
end

if strcmp(stopflag{:},'manual')
    fid = fopen('signals.par','w');
    fprintf(fid,'%% stop OptData/cmaes_out');
    fclose(fid);
end
