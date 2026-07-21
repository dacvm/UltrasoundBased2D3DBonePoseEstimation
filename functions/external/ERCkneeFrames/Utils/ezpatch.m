function [hO] = ezpatch(F,V,varargin)
%EZPATCH Interface to patch('Faces',F,'Vertices',V,(...))
%   EZPATCH(F,V,varargin), EZPATCH(V,F,varargin)
%   passes all arguments to patch (e.g. ezpatch((...),'FaceColor','none'))
%   EZPATCH(struct,varargin)
% 	The struct should have the fields F and V.
%   Implements several shorthands:
%       'fa'      -       'FaceAlpha'
%       'fc'      -       'FaceColor'
%       'ea'      -       'EdgeAlpha'
%       'ec'      -       'EdgeColor'
%       'n'       -       'none'
%       'fcn'     -       'FaceColor','none'
%       'ecn'     -       'EdgeColor','none'
%
%Example:
%   ezpatch(stlData,'fcn','ea',0.4)
%       is identical to
%   patch('Faces',stlData.F,'Vertices',stlData.V,"FaceColor','none','EdgeAlpha',0.4) ;
%       and also to
%   ezpatch(stlData.V,stlData.F,'ea',0.4,'fcn') ;
%
%   See also : patch

% Max Bakker, November 2016
if isstruct(F)
    if nargin > 1
        varargin(2:end+1) = varargin ;
        varargin{1} = V ;
    end
    sfn = fieldnames(F) ;
    
    %loosely compare the fieldnames to verti and fa, assign to that with
    %most correspondence
    datNames = {'verti','fa'} ; %(they both end in ces, so ignore that)
    for i = 1: 2
        for j = 1 : 2 
            %probably some fielname correspondence measure
            M(i,j) = sum(sum(bsxfun(@eq,repmat(lower(sfn{j}),[numel(datNames{i}),1]),(datNames{i})'))) ;
        end
    end
    
    [~,maxI] = max(M) ;
    %try coords and el;ements if verti and face didn't work
        %also its getting messy now, maybe refactor. 
    if maxI(1) == maxI(2) 
        datNames = {'coordinates','elements'} ; %(they both end in ces, so ignore that)
        for i = 1: 2
            for j = 1 : numel(sfn) 
                M(i,j) = sum(sum(bsxfun(@eq,repmat(lower(sfn{j}),[numel(datNames{i}),1]),(datNames{i})'))) ;
            end
        end
        
    [~,maxI] = max(M,[],2) ;
    end
    V = F.(sfn{maxI(1)}) ;
    F = F.(sfn{maxI(2)}) ;
end
%detects wether F is actually V by investigating integerness
if all(mod(V(:),1)==0) && any(mod(F(:),1)~=0)
    v =F ;
    F = V ;
    V = v ;
end
for vi = 1 : numel(varargin)
    if ischar(varargin{vi})
        switch(varargin{vi})
            case {'fa','FA','Fa'}
                varargin{vi} = 'FaceAlpha' ;
            case {'fc','FC','Fc'}
                varargin{vi} = 'FaceColor' ;
            case {'ea','EA','Ea'}
                varargin{vi} = 'EdgeAlpha' ;
            case {'ec', 'EC','Ec'}
                varargin{vi} = 'EdgeColor' ;
            case 'n'
                varargin{vi} = 'none' ;
            case {'fcn'}
                varargin{vi} = 'FaceColor' ;
                varargin(vi+2:end+1) = varargin(vi+1:end) ;
                varargin{vi+1} = 'none' ;
            case {'ecn'}
                varargin{vi} = 'EdgeColor' ;
                varargin(vi+2:end+1) = varargin(vi+1:end) ;
                varargin{vi+1} = 'none' ;
                
        end
    end
end

%add default options
if ~any(cellfun(@(vn) strcmp(vn,'FaceAlpha') ,varargin))
    varargin(end + [1,2]) = {'FaceAlpha',0.05} ;
end
if ~any(cellfun(@(vn) strcmp(vn,'EdgeAlpha') ,varargin))
    varargin(end + [1,2]) = {'EdgeAlpha',0.05} ;
end

if size(V,1)==3 && size(V,2)~=3
    V = V';
end
p = patch('faces',F,'Vertices',V,varargin{:}) ;
axis equal
if nargout > 0
    hO = p ;
end
end